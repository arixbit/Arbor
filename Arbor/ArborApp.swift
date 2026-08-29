import SwiftUI
import AppKit
import CryptoKit
import Network

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

private struct ExternalLogProviderInitializationError: Error, CustomStringConvertible, Sendable {
    let description: String
}

struct ExternalLogProviderDescriptor: Equatable, Sendable {
    let name: String
    let rootPath: String
}

/// Lifetime guard for one external Log tab. The SwiftUI host shares one
/// ContentView across tabs, so a closed tab needs an explicit disposer to
/// prevent an already-running result from being applied to that tab's state.
final class ExternalLogTabDisposer: @unchecked Sendable {
    private let lock = NSLock()
    private var disposed = false

    var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    func dispose() {
        lock.lock()
        disposed = true
        lock.unlock()
    }
}

/// Owns the provider-side resources for one external Git Log window. This is
/// the Swift equivalent of IntelliJ's GitExternalLogService registration of
/// external repositories before constructing a VcsLogManager.
final class ExternalLogProviderSession: @unchecked Sendable {
    let projectPath: String
    let rootPaths: [String]
    let roots: [GitRootInfo]
    let providers: [String: ExternalLogProviderDescriptor]
    let providerName = "Git"

    private let lock = NSLock()
    private var repositories: [String: Repository]
    private var disposed = false

    private init(
        projectPath: String,
        rootPaths: [String],
        roots: [GitRootInfo],
        providers: [String: ExternalLogProviderDescriptor],
        repositories: [String: Repository]
    ) {
        self.projectPath = projectPath
        self.rootPaths = rootPaths
        self.roots = roots
        self.providers = providers
        self.repositories = repositories
    }

    static func initialize(
        request: ExternalLogWindowRequest,
        executable: String
    ) throws -> ExternalLogProviderSession {
        _ = try testGitExecutable(path: executable)
        guard !request.rootPaths.isEmpty else {
            throw ExternalLogProviderInitializationError(
                description: "No Git roots were selected."
            )
        }

        var roots: [GitRootInfo] = []
        var providers: [String: ExternalLogProviderDescriptor] = [:]
        var repositories: [String: Repository] = [:]
        for rootPath in request.rootPaths {
            let canonicalPath = canonicalExternalLogPath(rootPath)
            let discoveredRoots = try discoverGitRoots(
                scanRoot: canonicalPath,
                maxDepth: 0
            )
            guard var root = discoveredRoots.first(where: {
                canonicalExternalLogPath($0.path) == canonicalPath
            }) else {
                throw ExternalLogProviderInitializationError(
                    description: "The selected Git root is no longer available: \(canonicalPath)"
                )
            }
            root.path = canonicalPath
            roots.append(root)
            providers[canonicalPath] = ExternalLogProviderDescriptor(
                name: "Git",
                rootPath: canonicalPath
            )
            repositories[canonicalPath] = try openRepository(path: canonicalPath)
        }
        return ExternalLogProviderSession(
            projectPath: request.projectPath,
            rootPaths: request.rootPaths,
            roots: roots,
            providers: providers,
            repositories: repositories
        )
    }

    func repository(for rootPath: String) -> Repository? {
        let canonicalPath = canonicalExternalLogPath(rootPath)
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return nil }
        return repositories[canonicalPath]
    }

    func repositories(for rootPaths: [String]) -> [String: Repository] {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return [:] }
        var selected: [String: Repository] = [:]
        for rootPath in rootPaths {
            let canonicalPath = canonicalExternalLogPath(rootPath)
            if let repository = repositories[canonicalPath] {
                selected[canonicalPath] = repository
            }
        }
        return selected
    }

    func dispose() {
        lock.lock()
        disposed = true
        repositories.removeAll()
        lock.unlock()
    }

    deinit {
        dispose()
    }
}

/// Owns the initialized provider set and the UI registrations for one
/// external Log surface. It is intentionally smaller than IntelliJ's full
/// VcsLogManager: Rust owns graph/query execution, while this object owns the
/// manager-level lifecycle and the SwiftUI tab registration boundary.
final class ExternalLogManager: @unchecked Sendable {
    let providerSession: ExternalLogProviderSession
    let name: String

    private let lock = NSLock()
    private var uiDisposers: [UUID: ExternalLogTabDisposer] = [:]
    private var initialized = false
    private var disposed = false

    private init(providerSession: ExternalLogProviderSession) {
        self.providerSession = providerSession
        let providerNames = Set(providerSession.providers.values.map(\.name)).sorted()
        self.name = "Vcs Log for " + providerNames.joined(separator: ", ")
    }

    static func initialize(
        request: ExternalLogWindowRequest,
        executable: String
    ) throws -> ExternalLogManager {
        let providerSession = try ExternalLogProviderSession.initialize(
            request: request,
            executable: executable
        )
        let manager = ExternalLogManager(providerSession: providerSession)
        manager.initialize()
        return manager
    }

    func initialize() {
        lock.lock()
        guard !disposed else {
            lock.unlock()
            return
        }
        initialized = true
        lock.unlock()
    }

    func registerUI(_ tabID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard initialized, !disposed, uiDisposers[tabID] == nil else { return false }
        uiDisposers[tabID] = ExternalLogTabDisposer()
        return true
    }

    func disposeUI(_ tabID: UUID) {
        lock.lock()
        let disposer = uiDisposers[tabID]
        lock.unlock()
        disposer?.dispose()
    }

    func isUIAlive(_ tabID: UUID) -> Bool {
        lock.lock()
        let isManagerDisposed = disposed || !initialized
        let disposer = uiDisposers[tabID]
        lock.unlock()
        return !isManagerDisposed && disposer?.isDisposed == false
    }

    func repository(for rootPath: String) -> Repository? {
        lock.lock()
        let isManagerDisposed = disposed || !initialized
        lock.unlock()
        guard !isManagerDisposed else { return nil }
        return providerSession.repository(for: rootPath)
    }

    func repositories(for rootPaths: [String]) -> [String: Repository] {
        lock.lock()
        let isManagerDisposed = disposed || !initialized
        lock.unlock()
        guard !isManagerDisposed else { return [:] }
        return providerSession.repositories(for: rootPaths)
    }

    func dispose() {
        lock.lock()
        guard !disposed else {
            lock.unlock()
            return
        }
        disposed = true
        initialized = false
        let disposers = Array(uiDisposers.values)
        uiDisposers.removeAll()
        lock.unlock()
        disposers.forEach { $0.dispose() }
        providerSession.dispose()
    }

    deinit {
        dispose()
    }
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

private struct ExternalLogWindowRequestUnavailableView: View {
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

/// The short-lived endpoint advertised to the embedded pinentry process.
/// Only loopback endpoints are accepted: the token is inherited from a
/// signed Git child process and is not a general-purpose remote service.
struct ArborPinentryEndpoint: Equatable, Sendable {
    static let prefix = "AR_PINENTRY="

    let publicKey: Data
    let host: String
    let port: UInt16

    var token: String {
        Self.prefix + [
            publicKey.base64EncodedString(),
            host,
            String(port)
        ].joined(separator: ":")
    }

    static func parse(_ value: String) -> ArborPinentryEndpoint? {
        let raw = value.hasPrefix(prefix)
            ? String(value.dropFirst(prefix.count))
            : value
        let fields = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let publicKey = Data(base64Encoded: String(fields[0])),
              publicKey.count == 32,
              fields[1] == "127.0.0.1",
              let port = UInt16(fields[2]),
              port > 0 else {
            return nil
        }
        return ArborPinentryEndpoint(publicKey: publicKey, host: String(fields[1]), port: port)
    }
}

/// CryptoKit transport for one pinentry request. Curve25519 avoids the
/// private-key RSA encryption used by the reference JVM helper while keeping
/// the same property: the helper can return a passphrase only to the Arbor
/// process that created the ephemeral session.
enum ArborPinentryCrypto {
    private static let salt = Data("Arbor pinentry v1".utf8)

    private static func key(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data
    ) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    static func encrypt(
        passphrase: String,
        clientPublicKey: Data,
        servicePrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        let sealed = try AES.GCM.seal(
            Data(passphrase.utf8),
            using: key(privateKey: servicePrivateKey, peerPublicKey: clientPublicKey)
        )
        guard let combined = sealed.combined else {
            throw NSError(domain: "Arbor.Pinentry", code: 1)
        }
        return combined.base64EncodedString()
    }

    static func decrypt(
        payload: String,
        servicePublicKey: Data,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        guard let combined = Data(base64Encoded: payload) else {
            throw NSError(domain: "Arbor.Pinentry", code: 2)
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(
            box,
            using: key(privateKey: clientPrivateKey, peerPublicKey: servicePublicKey)
        )
        guard let passphrase = String(data: plaintext, encoding: .utf8) else {
            throw NSError(domain: "Arbor.Pinentry", code: 3)
        }
        return passphrase
    }
}

/// The main Arbor process owns the UI prompt. The embedded pinentry helper
/// connects here over a short-lived loopback socket while GPG is signing.
final class ArborPinentryService: @unchecked Sendable {
    static let shared = ArborPinentryService()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.arbor.pinentry.service")
    private var listener: NWListener?
    private var activeToken: String?
    private var sessionUsers = 0

    func startSession() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let activeToken {
            sessionUsers += 1
            return activeToken
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 0)!
        )
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, servicePrivateKey: privateKey)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw NSError(
                domain: "Arbor.Pinentry",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Timed out starting the pinentry service."]
            )
        }
        guard listener.state == .ready,
              let port = listener.port?.rawValue,
              port > 0 else {
            listener.cancel()
            throw NSError(
                domain: "Arbor.Pinentry",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The pinentry service could not bind a loopback port."]
            )
        }

        let endpoint = ArborPinentryEndpoint(
            publicKey: privateKey.publicKey.rawRepresentation,
            host: "127.0.0.1",
            port: port
        )
        self.listener = listener
        self.activeToken = endpoint.token
        self.sessionUsers = 1
        return endpoint.token
    }

    /// Returns true only when the last operation released the session.
    @discardableResult
    func stopSession() -> Bool {
        lock.lock()
        guard activeToken != nil else {
            lock.unlock()
            return false
        }
        sessionUsers = max(0, sessionUsers - 1)
        guard sessionUsers == 0 else {
            lock.unlock()
            return false
        }
        let listener = self.listener
        self.listener = nil
        self.activeToken = nil
        lock.unlock()
        listener?.cancel()
        return true
    }

    private func accept(
        _ connection: NWConnection,
        servicePrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        connection.start(queue: queue)
        ArborPinentrySocket.receiveLine(connection: connection, buffer: Data()) { [weak self] line in
            self?.handle(
                line: line,
                connection: connection,
                servicePrivateKey: servicePrivateKey
            )
        }
    }

    private func handle(
        line: Data,
        connection: NWConnection,
        servicePrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        let request = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = request.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3,
              fields[0] == "GETPIN",
              let clientPublicKey = Data(base64Encoded: String(fields[1])) else {
            ArborPinentrySocket.send("ERR 83886181 malformed request", on: connection) {
                connection.cancel()
            }
            return
        }

        let description = ArborPinentryProtocol.unescape(String(fields[2]))
        Task { @MainActor in
            guard let passphrase = ArborPinentryPrompt.request(
                description: description,
                title: "GPG Passphrase",
                prompt: "Passphrase",
                okTitle: "OK",
                cancelTitle: "Cancel",
                errorMessage: ""
            ) else {
                ArborPinentrySocket.send("ERR 83886179 canceled", on: connection) {
                    connection.cancel()
                }
                return
            }

            do {
                let encrypted = try ArborPinentryCrypto.encrypt(
                    passphrase: passphrase,
                    clientPublicKey: clientPublicKey,
                    servicePrivateKey: servicePrivateKey
                )
                ArborPinentrySocket.send("D \(encrypted)\nOK", on: connection) {
                    connection.cancel()
                }
            } catch {
                ArborPinentrySocket.send("ERR 83886181 encryption failed", on: connection) {
                    connection.cancel()
                }
            }
        }
    }
}

/// Blocking socket helpers are isolated from the AppKit prompt. The helper
/// process is synchronous by design because GPG waits for the pinentry reply.
enum ArborPinentrySocket {
    private static let queue = DispatchQueue(label: "com.arbor.pinentry.socket")

    struct Response {
        let line: Data
        let clientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    }

    static func send(
        _ value: String,
        on connection: NWConnection,
        completion: @escaping () -> Void
    ) {
        connection.send(
            content: Data(value.utf8),
            completion: .contentProcessed { _ in completion() }
        )
    }

    static func receiveLine(
        connection: NWConnection,
        buffer: Data,
        completion: @escaping (Data) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { data, _, isComplete, _ in
            var buffer = buffer
            if let data {
                buffer.append(data)
                if let newline = buffer.firstIndex(of: 0x0A) {
                    completion(Data(buffer[..<newline]))
                    return
                }
            }
            if isComplete {
                completion(buffer)
            } else {
                receiveLine(connection: connection, buffer: buffer, completion: completion)
            }
        }
    }

    static func request(
        endpoint: ArborPinentryEndpoint,
        description: String
    ) -> Response? {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response: Data?
        var finished = false

        func finish(_ value: Data?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            response = value
            lock.unlock()
            semaphore.signal()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GETPIN \(clientPrivateKey.publicKey.rawRepresentation.base64EncodedString()) \(ArborPinentryProtocol.escape(description))\n"
                connection.send(
                    content: Data(request.utf8),
                    completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    }
                )
                receiveLine(connection: connection, buffer: Data()) { line in
                    finish(line)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            connection.cancel()
            return nil
        }
        connection.cancel()
        guard let response else { return nil }
        return Response(line: response, clientPrivateKey: clientPrivateKey)
    }
}

enum ArborPinentryClientOutcome {
    case unavailable
    case passphrase(String)
    case canceled
}

enum ArborPinentryClient {
    static func request(description: String) -> ArborPinentryClientOutcome {
        guard let value = ProcessInfo.processInfo.environment["PINENTRY_USER_DATA"],
              let endpoint = ArborPinentryEndpoint.parse(value),
              let exchange = ArborPinentrySocket.request(endpoint: endpoint, description: description),
              let response = String(data: exchange.line, encoding: .utf8) else {
            return .unavailable
        }

        if response.hasPrefix("ERR") {
            return response.localizedCaseInsensitiveContains("cancel") ? .canceled : .unavailable
        }
        guard response.hasPrefix("D ") else { return .unavailable }
        let payload = String(response.dropFirst(2))
        do {
            let passphrase = try ArborPinentryCrypto.decrypt(
                payload: payload,
                servicePublicKey: endpoint.publicKey,
                clientPrivateKey: exchange.clientPrivateKey
            )
            return .passphrase(passphrase)
        } catch {
            return .unavailable
        }
    }
}

/// Shared AppKit prompt used by the main service and the standalone helper.
@MainActor
enum ArborPinentryPrompt {
    static func request(
        description: String,
        title: String,
        prompt: String,
        okTitle: String,
        cancelTitle: String,
        errorMessage: String
    ) -> String? {
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title.isEmpty ? "GPG Passphrase" : title
        alert.informativeText = [description, errorMessage]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = prompt.isEmpty ? "Passphrase" : prompt
        alert.accessoryView = field
        alert.addButton(withTitle: okTitle.isEmpty ? "OK" : okTitle)
        alert.addButton(withTitle: cancelTitle.isEmpty ? "Cancel" : cancelTitle)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Minimal native pinentry helper used by the optional embedded GPG agent
/// launcher. GPG talks to this process over the standard pinentry
/// stdin/stdout protocol. When `PINENTRY_USER_DATA` is present, GETPIN is
/// proxied to the main process over the encrypted loopback session; otherwise
/// the helper owns the prompt as a standalone fallback. Neither path persists
/// the passphrase.
@MainActor
final class ArborPinentryProcess {
    nonisolated static let argument = "--arbor-pinentry"

    static var isInvocation: Bool {
        CommandLine.arguments.contains(argument)
    }

    private static var activeProcess: ArborPinentryProcess?

    static func startIfRequested() -> Bool {
        guard isInvocation else { return false }
        let process = ArborPinentryProcess()
        activeProcess = process
        process.start()
        return true
    }

    private let outputLock = NSLock()
    private var description = "Enter the passphrase to unlock the signing key."
    private var title = "GPG Passphrase"
    private var prompt = "Passphrase"
    private var okTitle = "OK"
    private var cancelTitle = "Cancel"
    private var errorMessage = ""
    private var isFinished = false

    private func start() {
        send("OK Pleased to meet you")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                Task { @MainActor [weak self] in
                    self?.handle(line)
                }
            }
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
    }

    private func handle(_ line: String) {
        guard !isFinished else { return }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = parts.first.map(String.init) ?? ""
        let value = parts.count == 2 ? String(parts[1]) : ""

        switch command {
        case "SETDESC":
            description = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETTITLE":
            title = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETPROMPT":
            prompt = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETOK":
            okTitle = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETCANCEL":
            cancelTitle = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETERROR":
            errorMessage = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "GETPIN":
            requestPassphrase()
        case "CONFIRM":
            requestConfirmation()
        case "CANCEL", "RESET":
            send("OK")
        case "OPTION", "SETKEYINFO", "SETCACHED", "SETNOTOK", "SETREPEAT", "SETREPEATERROR":
            send("OK")
        case "GETINFO":
            sendInfo(value)
        case "BYE":
            send("OK closing connection")
            finish()
        case "", "COMMENT", "MESSAGE":
            send("OK")
        default:
            send("ERR 83886181 unknown command <\(line)>")
        }
    }

    private func requestPassphrase() {
        switch ArborPinentryClient.request(description: description) {
        case let .passphrase(passphrase):
            send("D \(ArborPinentryProtocol.escape(passphrase))")
            send("OK")
        case .canceled:
            send("ERR 83886179 canceled")
        case .unavailable:
            guard let passphrase = ArborPinentryPrompt.request(
                description: description,
                title: title,
                prompt: prompt,
                okTitle: okTitle,
                cancelTitle: cancelTitle,
                errorMessage: errorMessage
            ) else {
                send("ERR 83886179 canceled")
                return
            }
            send("D \(ArborPinentryProtocol.escape(passphrase))")
            send("OK")
        }
    }

    private func requestConfirmation() {
        NSApp.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title.isEmpty ? "Confirm GPG operation" : title
        alert.informativeText = description
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            send("OK")
        } else {
            send("ERR 83886179 canceled")
        }
        NSApp.setActivationPolicy(.prohibited)
    }

    private func sendInfo(_ value: String) {
        switch value {
        case "pid":
            send("D \(ProcessInfo.processInfo.processIdentifier)")
            send("OK")
        case "flavor":
            send("D Arbor")
            send("OK")
        case "version":
            send("D 1.0")
            send("OK")
        default:
            send("OK")
        }
    }

    private func send(_ line: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        NSApp.terminate(nil)
    }
}

enum ArborPinentryProtocol {
    static func escape(_ value: String) -> String {
        value.utf8.reduce(into: "") { result, byte in
            if byte == 0x25 || byte < 0x20 || byte > 0x7E {
                result += String(format: "%%%02X", byte)
            } else {
                result.append(Character(UnicodeScalar(byte)))
            }
        }
    }

    static func unescape(_ value: String) -> String {
        var bytes: [UInt8] = []
        let input = Array(value.utf8)
        var index = 0
        while index < input.count {
            if input[index] == 0x25,
               index + 2 < input.count,
               let high = hexValue(input[index + 1]),
               let low = hexValue(input[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(input[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

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
        let languageRawValue = UserDefaults.standard.string(forKey: "arbor.appLanguage")
            ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: languageRawValue) ?? .system

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

@main
struct ArborApp: App {
    @NSApplicationDelegateAdaptor(ArborAppDelegate.self) private var appDelegate
    @AppStorage("arbor.appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue

    init() {
        ArborAppIconController.install()
        let savedPath = UserDefaults.standard.string(forKey: "arbor.git.executable") ?? ""
        if !savedPath.isEmpty {
            _ = try? setGitExecutable(path: savedPath)
        }
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
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
        Settings {
            DiagnosticsSettingsView()
                .environment(\.locale, appLanguage.locale)
        }
    }
}

extension Notification.Name {
    static let arborOpenProjectPanel = Notification.Name("arbor.openProjectPanel")
    static let arborInitProjectPanel = Notification.Name("arbor.initProjectPanel")
    static let arborCloneProjectDialog = Notification.Name("arbor.cloneProjectDialog")
    static let arborVCSAction = Notification.Name("arbor.vcsAction")
    static let arborOpenCommitDetail = Notification.Name("arbor.openCommitDetail")
    static let arborOpenMultiRootConflictResolver = Notification.Name("arbor.openMultiRootConflictResolver")
    static let arborRollbackMerge = Notification.Name("arbor.rollbackMerge")
    static let arborDeleteMergedBranch = Notification.Name("arbor.deleteMergedBranch")
}

private struct ArborRepositoryShallowKey: FocusedValueKey {
    typealias Value = Bool
}

private struct ArborRepositoryAvailableKey: FocusedValueKey {
    typealias Value = Bool
}

struct ArborVCSActionContext: Equatable {
    let hasRepository: Bool
    /// GitCreateNewBranchAction starts from HEAD and is disabled when any
    /// repository in the top-level action scope is still unborn.
    let allRepositoriesHaveHeadCommit: Bool
    let hasCurrentBranch: Bool
    let hasLocalChanges: Bool
    let hasUnstagedTrackedChanges: Bool
    let hasStagedChanges: Bool
    let hasConflicts: Bool
    let isShallowRepository: Bool
    let hasRemotes: Bool
    let hasFetchInProgress: Bool
    let hasBackgroundVCSOperation: Bool
    let projectPath: String?
    let hasMultipleGitRoots: Bool
    let hasProjectCommitChanges: Bool
    let hasTrackedUpstream: Bool
    let hasSingleGitRoot: Bool
    let hasRepositoryOperationInProgress: Bool
    let hasMergeInProgress: Bool
    let hasRebaseInProgress: Bool
    let hasNormalOrDetachedRepository: Bool
    /// The Changes Browser's Revert action is selection-scoped. Keep the
    /// selected path in the focused context so the main menu cannot silently
    /// fall back to the first dirty file in the repository.
    let selectedLocalChangePath: String?
    /// Git.RevertResolved is also selection-scoped. A resolved conflict path
    /// must be explicitly selected before the main-menu action is enabled.
    let selectedResolvedConflictPath: String?
    /// Git.FileActions is selection-scoped as well. Keep all presentation
    /// facts together so a main-menu action cannot fall back to an arbitrary
    /// dirty path or route a nested repository through the primary root.
    let selectedFileAction: ArborSelectedGitFileContext?

    init(
        hasRepository: Bool,
        allRepositoriesHaveHeadCommit: Bool = true,
        hasCurrentBranch: Bool,
        hasLocalChanges: Bool,
        hasUnstagedTrackedChanges: Bool,
        hasStagedChanges: Bool,
        hasConflicts: Bool,
        isShallowRepository: Bool,
        hasRemotes: Bool,
        hasFetchInProgress: Bool = false,
        hasBackgroundVCSOperation: Bool = false,
        projectPath: String? = nil,
        hasMultipleGitRoots: Bool = false,
        hasProjectCommitChanges: Bool = false,
        hasTrackedUpstream: Bool = false,
        hasSingleGitRoot: Bool = false,
        hasRepositoryOperationInProgress: Bool = false,
        hasMergeInProgress: Bool = false,
        hasRebaseInProgress: Bool = false,
        hasNormalOrDetachedRepository: Bool = true,
        selectedLocalChangePath: String? = nil,
        selectedResolvedConflictPath: String? = nil,
        selectedFileAction: ArborSelectedGitFileContext? = nil
    ) {
        self.hasRepository = hasRepository
        self.allRepositoriesHaveHeadCommit = allRepositoriesHaveHeadCommit
        self.hasCurrentBranch = hasCurrentBranch
        self.hasLocalChanges = hasLocalChanges
        self.hasUnstagedTrackedChanges = hasUnstagedTrackedChanges
        self.hasStagedChanges = hasStagedChanges
        self.hasConflicts = hasConflicts
        self.isShallowRepository = isShallowRepository
        self.hasRemotes = hasRemotes
        self.hasFetchInProgress = hasFetchInProgress
        self.hasBackgroundVCSOperation = hasBackgroundVCSOperation
        self.projectPath = projectPath
        self.hasMultipleGitRoots = hasMultipleGitRoots
        self.hasProjectCommitChanges = hasProjectCommitChanges
        self.hasTrackedUpstream = hasTrackedUpstream
        self.hasSingleGitRoot = hasSingleGitRoot
        self.hasRepositoryOperationInProgress = hasRepositoryOperationInProgress
        self.hasMergeInProgress = hasMergeInProgress
        self.hasRebaseInProgress = hasRebaseInProgress
        self.hasNormalOrDetachedRepository = hasNormalOrDetachedRepository
        self.selectedLocalChangePath = selectedLocalChangePath
        self.selectedResolvedConflictPath = selectedResolvedConflictPath
        self.selectedFileAction = selectedFileAction
    }
}

/// The focused selection needed by IntelliJ's Git.FileActions group. The
/// booleans are computed from the same status model that renders the file
/// tree, while `owningRootPath` is resolved from the canonical project path.
/// Keeping this as a value type makes menu presentation testable without
/// constructing SwiftUI views.
struct ArborSelectedGitFileContext: Equatable {
    let path: String
    let rootRelativePath: String
    let isDirectory: Bool
    let owningRootPath: String
    let isPrimaryRoot: Bool
    let canCheckin: Bool
    let canAdd: Bool
    let canAnnotate: Bool
    let canCompareWithHead: Bool
    let canCompareWithSelectedRevision: Bool
}

/// Focused command context for the repository currently owning the live
/// operation state. ProjectCommands must not infer a recovery root from the
/// project-wide "some operation is active" booleans: in a multi-root project
/// that could route Continue/Abort to the wrong repository.
struct ArborVCSOperationContext {
    let rootPath: String
    let kind: OperationKind
    let hasConflicts: Bool
}

private struct ArborVCSOperationContextKey: FocusedValueKey {
    typealias Value = ArborVCSOperationContext
}

private struct ArborVCSActionContextKey: FocusedValueKey {
    typealias Value = ArborVCSActionContext
}

extension FocusedValues {
    var arborRepositoryIsShallow: Bool? {
        get { self[ArborRepositoryShallowKey.self] }
        set { self[ArborRepositoryShallowKey.self] = newValue }
    }

    var arborRepositoryAvailable: Bool? {
        get { self[ArborRepositoryAvailableKey.self] }
        set { self[ArborRepositoryAvailableKey.self] = newValue }
    }

    var arborVCSActionContext: ArborVCSActionContext? {
        get { self[ArborVCSActionContextKey.self] }
        set { self[ArborVCSActionContextKey.self] = newValue }
    }

    var arborVCSOperationContext: ArborVCSOperationContext? {
        get { self[ArborVCSOperationContextKey.self] }
        set { self[ArborVCSOperationContextKey.self] = newValue }
    }
}

enum ArborVCSAction: String, CaseIterable, Hashable {
    case update
    case reset
    case resetToRemoteBranch
    case commit
    case commitAndPush
    case push
    case fetch
    case fetchAll
    case retryAutoFetch
    case enableAutoFetch
    case disableAutoFetchSuggestion
    case fetchPrune
    case fetchUnshallow
    case pull
    case pullMerge
    case pullRebase
    case showStagingArea
    case showShelf
    case showStash
    case revertSelectedChanges
    case branches
    case merge
    case rebase
    case stash
    case unstash
    case shelve
    case applyPatch
    case applyPatchFromClipboard
    case newBranch
    case newTag
    case configureRemotes
    case worktrees
    case stageTracked
    case stageAll
    case copyCurrentBranchName
    case resolveConflicts
    case revertResolved
    case searchEverywhere
    case showLog
    case showExternalLog
    case showOperations
    case showGitRoots
    case showGitConsole
    case refresh
    case quickActions
    case fileCheckin
    case fileAdd
    case fileAnnotate
    case fileCompareSameVersion
    case fileCompareSelectedRevision
    case fileCompareWithBranch
    case fileHistory
}

func isArborVCSActionEnabled(
    _ action: ArborVCSAction,
    in context: ArborVCSActionContext?
) -> Bool {
    guard let context else { return false }

    switch action {
    case .searchEverywhere:
        return context.hasRepository
    case .update:
        return context.hasRepository && !context.hasBackgroundVCSOperation
    case .showLog, .showOperations, .showGitRoots, .showGitConsole, .showStagingArea, .showShelf, .showStash, .refresh,
         .branches, .stash, .unstash, .shelve, .applyPatch,
         .newTag, .configureRemotes, .worktrees:
        return context.hasRepository
    case .newBranch:
        return context.hasRepository && context.allRepositoriesHaveHeadCommit
    case .revertSelectedChanges:
        return context.hasRepository
            && context.selectedLocalChangePath != nil
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .merge:
        return context.hasRepository
            && !context.hasMergeInProgress
            && context.hasNormalOrDetachedRepository
    case .rebase:
        return context.hasRepository
            && !context.hasRebaseInProgress
            && context.hasNormalOrDetachedRepository
    case .reset:
        return context.hasRepository
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
            && context.hasNormalOrDetachedRepository
    case .resetToRemoteBranch:
        return context.hasRepository
            && context.hasCurrentBranch
            && context.hasSingleGitRoot
            && context.hasTrackedUpstream
    case .applyPatchFromClipboard:
        return context.hasRepository
    case .showExternalLog:
        return context.hasRepository && context.projectPath != nil
    case .commit:
        return context.hasRepository && context.hasLocalChanges
    case .commitAndPush:
        return context.hasRepository
            && (
                context.hasCurrentBranch && context.hasLocalChanges
                    || (context.hasMultipleGitRoots && context.hasProjectCommitChanges)
            )
    case .push:
        return context.hasRepository
    case .pull, .pullMerge, .pullRebase:
        return context.hasRepository
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fetch, .fetchAll, .fetchPrune:
        return context.hasRepository
            && context.hasRemotes
            && !context.hasFetchInProgress
    case .retryAutoFetch, .enableAutoFetch, .disableAutoFetchSuggestion:
        return context.hasRepository
    case .fetchUnshallow:
        return context.hasRepository
            && context.isShallowRepository
            && !context.hasFetchInProgress
    case .stageTracked:
        return context.hasRepository && context.hasUnstagedTrackedChanges
    case .stageAll:
        return context.hasRepository && context.hasLocalChanges
    case .copyCurrentBranchName:
        return context.hasRepository && context.hasCurrentBranch
    case .resolveConflicts:
        return context.hasRepository && context.hasConflicts
    case .revertResolved:
        return context.hasRepository
            && context.selectedResolvedConflictPath != nil
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fileCheckin:
        return context.hasRepository
            && context.selectedFileAction?.canCheckin == true
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fileAdd:
        return context.hasRepository
            && context.selectedFileAction?.canAdd == true
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fileAnnotate:
        return context.hasRepository
            && context.selectedFileAction?.canAnnotate == true
            && !context.hasBackgroundVCSOperation
    case .fileCompareSameVersion:
        return context.hasRepository
            && context.selectedFileAction?.canCompareWithHead == true
    case .fileCompareSelectedRevision:
        return context.hasRepository
            && context.selectedFileAction?.canCompareWithSelectedRevision == true
    case .fileCompareWithBranch:
        return context.hasRepository && context.selectedFileAction != nil
    case .fileHistory:
        return context.hasRepository
            && context.selectedFileAction?.isDirectory == false
    case .quickActions:
        return context.hasRepository
    }
}

/// Resolve the focused Changes Browser selection for the main-menu Revert
/// action. The order mirrors the visible workspaces: Commit/Stash preview,
/// diff selection, then Project selection. A path is only eligible when it is
/// a tracked, non-conflicted change; untracked and ignored files require a
/// different destructive action and must not be deleted by Revert.
func arborSelectedRevertPath(
    entries: [FileEntry],
    candidates: [String?],
    headPresentByPath: [String: Bool]? = nil
) -> String? {
    for path in candidates.compactMap({ $0 }) {
        guard let entry = entries.first(where: { $0.path == path }) else { continue }
        if let headPresentByPath, headPresentByPath[path] != true { continue }
        let hasTrackedChange = [entry.staged, entry.unstaged].contains {
            $0 != .unchanged
                && $0 != .ignored
                && $0 != .untracked
                && $0 != .conflicted
        }
        guard hasTrackedChange,
              entry.staged != .conflicted,
              entry.unstaged != .conflicted,
              entry.staged != .ignored,
              entry.unstaged != .ignored,
              entry.unstaged != .untracked else { continue }
        return path
    }
    return nil
}

/// Match IntelliJ's `AbstractCommonUpdateAction` boundary. Update Project is
/// disabled while any background VCS operation owns the transport/feedback
/// lane, including multi-root runners whose progress is tracked separately.
func isArborBackgroundVCSOperationInProgress(
    feedbackIsRunning: Bool,
    multiRootIsRunning: Bool
) -> Bool {
    feedbackIsRunning || multiRootIsRunning
}

/// Match IntelliJ's `GitFetch.update()` busy boundary. Fetch, prune, branch
/// fetch, and unshallow all use the same Git transport lane, so a second
/// fetch action must remain visible but disabled until the first one ends.
func isArborFetchInProgress(
    isRunning: Bool,
    operationName: String?
) -> Bool {
    guard isRunning, let operationName else { return false }
    let normalized = operationName.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.hasPrefix("Fetch") || normalized == "Prune remote branches"
}

/// Match IntelliJ's project-wide rebase guard: a rebase in any discovered
/// Git root hides the project-level Rebase action, even when another root is
/// currently selected in the window.
func isArborRebaseInProgress(
    currentOperation: OperationKind?,
    roots: [GitRootInfo],
    hasMultiRootSession: Bool
) -> Bool {
    currentOperation == .rebase
        || hasMultiRootSession
        || roots.contains { $0.operation == .rebase }
}

/// Match IntelliJ's project-wide merge guard: a merge in any discovered Git
/// root hides the project-level Merge action, even when another root is
/// currently selected in the window.
func isArborMergeInProgress(
    currentOperation: OperationKind?,
    roots: [GitRootInfo]
) -> Bool {
    currentOperation == .merge
        || roots.contains { $0.operation == .merge }
}

/// Match IntelliJ's `NORMAL`/`DETACHED` repository filter for Rebase. The
/// selected root's live operation state wins over a potentially older root
/// discovery snapshot; other roots use their project-wide snapshot state.
func hasArborNormalOrDetachedRepository(
    currentOperation: OperationKind?,
    currentRootPath: String?,
    roots: [GitRootInfo]
) -> Bool {
    guard !roots.isEmpty else { return currentOperation == nil }
    let normalizedCurrentRoot = currentRootPath.map(canonicalExternalLogPath)
    return roots.contains { root in
        if let normalizedCurrentRoot,
           canonicalExternalLogPath(root.path) == normalizedCurrentRoot {
            return currentOperation == nil
        }
        return root.operation == nil
    }
}

/// Match IntelliJ's presentation boundary for actions that cannot be
/// reopened while their own repository operation is active.
func isArborVCSActionVisible(
    _ action: ArborVCSAction,
    in context: ArborVCSActionContext?
) -> Bool {
    guard let context else {
        return action != .merge && action != .rebase
    }
    switch action {
    case .merge:
        return context.hasRepository && !context.hasMergeInProgress
    case .rebase:
        return context.hasRepository && !context.hasRebaseInProgress
    default:
        return true
    }
}

/// The context-aware action list exposed by IntelliJ's
/// `GitQuickListContentProvider`. Keep this model separate from the larger
/// VCS menu: the quick list is intentionally short, searchable, and ordered
/// for keyboard use.
struct VCSQuickActionItem: Identifiable, Equatable {
    enum Section: String, CaseIterable, Hashable {
        case commit
        case repository
        case workspace
    }

    let action: ArborVCSAction
    let title: String
    let subtitle: String
    let systemImage: String
    let section: Section
    let isEnabled: Bool

    var id: String { action.rawValue }
}

func vcsQuickActionItems(
    isShallowRepository: Bool,
    hasCurrentBranch: Bool,
    hasConflicts: Bool,
    hasUnstagedTrackedChanges: Bool,
    hasUnstagedChanges: Bool,
    hasRepository: Bool = true,
    hasCommitChanges: Bool? = nil,
    hasFetchInProgress: Bool = false
) -> [VCSQuickActionItem] {
    var items = [
        VCSQuickActionItem(
            action: .commit,
            title: "Commit Changes…",
            subtitle: "Review staged and local changes before committing",
            systemImage: "checkmark.circle",
            section: .commit,
            isEnabled: hasRepository && (hasCommitChanges ?? hasUnstagedChanges)
        ),
        VCSQuickActionItem(
            action: .stageTracked,
            title: "Stage Changes",
            subtitle: "Stage tracked worktree changes before committing",
            systemImage: "arrow.right.circle",
            section: .commit,
            isEnabled: hasRepository && hasUnstagedTrackedChanges
        ),
        VCSQuickActionItem(
            action: .branches,
            title: "Branches…",
            subtitle: "Checkout, merge, rebase, pull, push, and branch management",
            systemImage: "arrow.triangle.branch",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .push,
            title: "Push…",
            subtitle: "Push the current root with refspec and lease options",
            systemImage: "arrow.up.circle",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .stash,
            title: "Stash…",
            subtitle: "Save local changes to Git's stash stack",
            systemImage: "archivebox",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .unstash,
            title: "Unstash Changes…",
            subtitle: "Apply or pop a selected stash",
            systemImage: "arrow.down.doc",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .worktrees,
            title: "Worktrees",
            subtitle: "Open, create, lock, unlock, prune, or remove worktrees",
            systemImage: "square.stack.3d.up",
            section: .workspace,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .stageAll,
            title: "Stage All Changes",
            subtitle: "Stage tracked and untracked changes",
            systemImage: "arrow.right.to.line",
            section: .workspace,
            isEnabled: hasRepository && hasUnstagedChanges
        ),
        VCSQuickActionItem(
            action: .copyCurrentBranchName,
            title: "Copy Current Branch Name",
            subtitle: "Copy the current branch ref to the clipboard",
            systemImage: "doc.on.doc",
            section: .workspace,
            isEnabled: hasRepository && hasCurrentBranch
        ),
        VCSQuickActionItem(
            action: .resolveConflicts,
            title: "Resolve Conflicts",
            subtitle: "Open the Git root conflict resolver",
            systemImage: "exclamationmark.triangle",
            section: .workspace,
            isEnabled: hasRepository && hasConflicts
        )
    ]
    if isShallowRepository {
        items.append(
            VCSQuickActionItem(
                action: .fetchUnshallow,
                title: "Fetch Full History…",
                subtitle: "Convert this shallow clone into a complete history",
                systemImage: "arrow.down.to.line",
                section: .repository,
                isEnabled: hasRepository && !hasFetchInProgress
            )
        )
    }
    return items
}

func filteredVCSQuickActionItems(
    _ items: [VCSQuickActionItem],
    query: String
) -> [VCSQuickActionItem] {
    let tokens = query
        .split(whereSeparator: { $0.isWhitespace })
        .map { String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return items }
    return items.filter { item in
        let haystack = "\(item.title) \(item.subtitle)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

/// Codable form of the exact roots that completed a multi-root checkout.
/// The live UniFFI record intentionally stays process-local; this form lets
/// the rollback action survive an app restart without re-discovering a
/// different set of roots.
struct PersistedMultiRootCheckoutTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let checkedOut: Bool
    let previousBranch: String?
    let previousHead: String?
    let expectedHead: String?
    let expectedBranch: String?
    let createdBranch: String?

    init(_ target: MultiRootBranchTarget) {
        rootPath = target.rootPath
        checkedOut = target.checkedOut
        previousBranch = target.previousBranch
        previousHead = target.previousHead
        expectedHead = target.expectedHead
        expectedBranch = target.expectedBranch
        createdBranch = target.createdBranch
    }

    func makeLiveTarget() -> MultiRootBranchTarget {
        MultiRootBranchTarget(
            rootPath: rootPath,
            checkedOut: checkedOut,
            previousBranch: previousBranch,
            previousHead: previousHead,
            expectedHead: expectedHead,
            expectedBranch: expectedBranch,
            createdBranch: createdBranch
        )
    }
}

/// Codable identity for a Changes Browser row. The owning root is part of the
/// identity because the same relative path can exist in multiple nested Git
/// repositories. Batch stage/unstage retry actions persist this pair rather
/// than relying on the currently discovered project roots.
struct PersistedMultiRootChangePath: Codable, Equatable, Sendable {
    let rootPath: String
    let path: String
    let oldPath: String?

    init(_ selection: MultiRootChangeSelection) {
        rootPath = selection.rootPath
        path = selection.path
        oldPath = selection.oldPath
    }

    init(rootPath: String, path: String, oldPath: String? = nil) {
        self.rootPath = rootPath
        self.path = path
        self.oldPath = oldPath
    }

    func makeLiveSelection() -> MultiRootChangeSelection {
        MultiRootChangeSelection(rootPath: rootPath, path: path, oldPath: oldPath)
    }
}

/// Codable state for a multi-root New Branch partial rollback. Unlike a
/// checkout target, an existing branch may need its previous tip restored
/// rather than deleted.
struct PersistedMultiRootBranchCreateTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let checkedOut: Bool
    let previousBranch: String?
    let previousHead: String?
    let expectedHead: String?
    let expectedBranch: String?
    let previousBranchTip: String?
    let expectedBranchTip: String?

    init(_ target: MultiRootBranchCreateTarget) {
        rootPath = target.rootPath
        checkedOut = target.checkedOut
        previousBranch = target.previousBranch
        previousHead = target.previousHead
        expectedHead = target.expectedHead
        expectedBranch = target.expectedBranch
        previousBranchTip = target.previousBranchTip
        expectedBranchTip = target.expectedBranchTip
    }

    func makeLiveTarget() -> MultiRootBranchCreateTarget {
        MultiRootBranchCreateTarget(
            rootPath: rootPath,
            checkedOut: checkedOut,
            previousBranch: previousBranch,
            previousHead: previousHead,
            expectedHead: expectedHead,
            expectedBranch: expectedBranch,
            previousBranchTip: previousBranchTip,
            expectedBranchTip: expectedBranchTip
        )
    }
}

/// Codable post-rename state for a multi-root branch rollback. The rollback
/// only renames the new ref back when the ref tip and current branch identity
/// still match this snapshot; a later user change therefore fails closed.
struct PersistedMultiRootBranchRenameRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let oldName: String
    let newName: String
    let expectedNewTip: String
    /// Empty string represents detached HEAD.
    let expectedCurrentBranch: String
    /// Upstream after the forward rename; nil means no tracking ref.
    let expectedUpstream: String?
    let upstream: String?
}

/// The exact ref and warning snapshot captured before a local branch deletion.
/// Keeping this data instead of a Repository handle makes both Restore and
/// View Commits safe to carry through Operation Log/native notifications.
struct PersistedBranchDeleteCommit: Codable, Equatable, Sendable {
    let id: String
    let shortID: String
    let summary: String
    let time: Int64
}

struct PersistedBranchDeleteRecoveryTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let branchName: String
    let tipID: String
    let upstream: String?
    let baseBranches: [String]
    let unmergedCommits: [PersistedBranchDeleteCommit]

    init(
        rootPath: String,
        branchName: String,
        tipID: String,
        upstream: String?,
        baseBranches: [String] = [],
        unmergedCommits: [PersistedBranchDeleteCommit] = []
    ) {
        self.rootPath = rootPath
        self.branchName = branchName
        self.tipID = tipID
        self.upstream = upstream
        self.baseBranches = baseBranches
        self.unmergedCommits = unmergedCommits
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath
        case branchName
        case tipID
        case upstream
        case baseBranches
        case unmergedCommits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        branchName = try container.decode(String.self, forKey: .branchName)
        tipID = try container.decode(String.self, forKey: .tipID)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        baseBranches = try container.decodeIfPresent([String].self, forKey: .baseBranches) ?? []
        unmergedCommits = try container.decodeIfPresent(
            [PersistedBranchDeleteCommit].self,
            forKey: .unmergedCommits
        ) ?? []
    }
}

/// Codable form of the expected-HEAD guarded targets used by multi-root
/// rebase rollback/undo. The live SwiftUI context is process-local; these
/// immutable values make the recovery action safe to carry across relaunch.
struct PersistedMultiRootRebaseRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let branch: String
    let protectionCommitID: String?

    init(_ target: MultiRootRebaseRollbackTarget) {
        rootPath = target.rootPath
        displayName = target.displayName
        initialHead = target.initialHead
        expectedHead = target.expectedHead
        branch = target.branch
        protectionCommitID = target.protectionCommitID
    }

    func makeLiveTarget() -> MultiRootRebaseRollbackTarget {
        MultiRootRebaseRollbackTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            branch: branch,
            protectionCommitID: protectionCommitID
        )
    }
}

/// Codable expected-HEAD targets for a multi-root Merge rollback. The target
/// carries enough state to fail closed after relaunch or a later user change.
struct PersistedMultiRootMergeRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let operationPending: Bool

    init(_ target: MultiRootMergeRollbackTarget) {
        rootPath = target.rootPath
        displayName = target.displayName
        initialHead = target.initialHead
        expectedHead = target.expectedHead
        operationPending = target.operationPending
    }

    func makeLiveTarget() -> MultiRootMergeRollbackTarget {
        MultiRootMergeRollbackTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            operationPending: operationPending
        )
    }
}

/// Codable expected-HEAD targets for a compound Update Project rollback. The
/// expected branch is empty for detached HEAD and protects against a user
/// switching to another ref that happens to point at the same commit.
struct PersistedMultiRootUpdateRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let expectedHeadBranch: String?
    let ignoredPaths: [String]

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        expectedHeadBranch: String? = nil,
        ignoredPaths: [String] = []
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.expectedHeadBranch = expectedHeadBranch
        self.ignoredPaths = ignoredPaths
    }
}

/// Codable expected-HEAD targets for a soft-reset rollback. Soft reset only
/// moves the ref, so the corresponding engine action intentionally does not
/// carry or restore index/worktree snapshots.
struct PersistedMultiRootResetRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    /// Empty string represents detached HEAD.
    let expectedHeadBranch: String?

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        expectedHeadBranch: String?
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.expectedHeadBranch = expectedHeadBranch
    }

    func makeLiveTarget() -> MultiRootResetRollbackTarget {
        MultiRootResetRollbackTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            mode: .soft,
            expectedHeadBranch: expectedHeadBranch
        )
    }
}

/// Durable full-scene Reset undo context. The mode is stored as a small
/// Codable value so Operation Log/native notifications remain independent of
/// the generated UniFFI enum representation.
enum PersistedResetMode: String, Codable, Sendable {
    case soft
    case mixed
    case hard
    case keep

    init(_ mode: ResetMode) {
        switch mode {
        case .soft: self = .soft
        case .mixed: self = .mixed
        case .hard: self = .hard
        case .keep: self = .keep
        }
    }

    var live: ResetMode {
        switch self {
        case .soft: return .soft
        case .mixed: return .mixed
        case .hard: return .hard
        case .keep: return .keep
        }
    }
}

struct PersistedResetRecoveryTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let expectedHeadBranch: String?
    let mode: PersistedResetMode
    let rollbackID: String

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        expectedHeadBranch: String?,
        mode: ResetMode,
        rollbackID: String
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.expectedHeadBranch = expectedHeadBranch
        self.mode = PersistedResetMode(mode)
        self.rollbackID = rollbackID
    }

    func makeLiveTarget() -> ResetRecoveryTarget {
        ResetRecoveryTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            expectedHeadBranch: expectedHeadBranch,
            mode: mode.live,
            rollbackId: rollbackID
        )
    }
}

/// The immutable range attached to IntelliJ's update-session "View Commits"
/// action. A range must retain its owning Git root because the same object id
/// is not a project-wide identity in a multi-root workspace.
struct PersistedLogRevisionRange: Codable, Equatable, Sendable {
    let rootPath: String
    let oldRevision: String
    let newRevision: String
}

/// Codable commit context for a multi-root retry action. The generated
/// UniFFI options type intentionally stays a live-process value; notifications
/// and Operation Log entries need a stable on-disk representation instead.
struct PersistedMultiRootCommitCheck: Codable, Equatable, Sendable {
    let command: String
    let args: [String]

    init(_ check: MultiRootCommitCheck) {
        command = check.command
        args = check.args
    }

    func makeLive() -> MultiRootCommitCheck {
        MultiRootCommitCheck(command: command, args: args)
    }
}

struct PersistedMultiRootCommitRetry: Codable, Equatable, Sendable {
    let message: String
    let skipHooks: Bool
    let authorName: String?
    let authorEmail: String?
    let committerName: String?
    let committerEmail: String?
    let signOff: Bool
    let coAuthors: [String]
    let amend: Bool
    let runBeforeCommitChecks: Bool
    let beforeCommitCommands: [PersistedMultiRootCommitCheck]
    /// Optional for backwards-compatible history entries created before the
    /// project-level Commit and Push executor existed.
    let pushAfterCommit: Bool?
    let pushRootPaths: [String]?
    /// When present, retry only these root-qualified Changes Browser rows.
    /// Nil preserves the older root-level Commit retry payload.
    let selectedPaths: [PersistedMultiRootChangePath]?

    init(
        message: String,
        options: MultiRootCommitOptions,
        pushAfterCommit: Bool = false,
        pushRootPaths: [String] = [],
        selectedPaths: [PersistedMultiRootChangePath]? = nil
    ) {
        self.message = message
        skipHooks = options.skipHooks
        authorName = options.authorName
        authorEmail = options.authorEmail
        committerName = options.committerName
        committerEmail = options.committerEmail
        signOff = options.signOff
        coAuthors = options.coAuthors
        amend = options.amend
        runBeforeCommitChecks = options.runBeforeCommitChecks
        beforeCommitCommands = options.beforeCommitCommands.map(PersistedMultiRootCommitCheck.init)
        self.pushAfterCommit = pushAfterCommit ? true : nil
        self.pushRootPaths = pushRootPaths.isEmpty ? nil : pushRootPaths
        self.selectedPaths = selectedPaths
    }

    func makeLiveOptions() -> MultiRootCommitOptions {
        MultiRootCommitOptions(
            skipHooks: skipHooks,
            authorName: authorName,
            authorEmail: authorEmail,
            committerName: committerName,
            committerEmail: committerEmail,
            signOff: signOff,
            coAuthors: coAuthors,
            amend: amend,
            runBeforeCommitChecks: runBeforeCommitChecks,
            beforeCommitCommands: beforeCommitCommands.map { $0.makeLive() }
        )
    }
}

/// Durable parameters for a rejected single-root Push. The recovery action is
/// intentionally limited to the checked-out branch: custom refspecs and
/// detached sources cannot be repaired by pulling the current branch without
/// risking a push of the wrong object.
struct PersistedPushRecovery: Codable, Equatable, Sendable {
    let remote: String
    let branch: String
    let force: Bool
    let forceWithLease: Bool
    let setUpstream: Bool
    /// Preserve a custom source/target refspec for a direct Push retry. A
    /// rejected refspec push cannot safely be reconstructed from the current
    /// branch alone.
    let refspec: String?
    let tagModeRaw: String?
    let skipHooks: Bool
    let rebase: Bool

    init(
        remote: String,
        branch: String,
        force: Bool,
        forceWithLease: Bool,
        setUpstream: Bool,
        refspec: String? = nil,
        tagModeRaw: String? = nil,
        skipHooks: Bool = false,
        rebase: Bool
    ) {
        self.remote = remote
        self.branch = branch
        self.force = force
        self.forceWithLease = forceWithLease
        self.setUpstream = setUpstream
        self.refspec = refspec
        self.tagModeRaw = tagModeRaw
        self.skipHooks = skipHooks
        self.rebase = rebase
    }
}

/// Durable context for Create Branch from Stash. The stash index is only a
/// presentation position and changes after another stash is created or
/// dropped, so retries use the stash object id plus the repository state that
/// the original operation observed.
struct PersistedStashBranchRetry: Codable, Equatable, Sendable {
    let stashID: String
    let branch: String
    let expectedCurrentBranch: String?
    let expectedCurrentHead: String?

    init(
        stashID: String,
        branch: String,
        expectedCurrentBranch: String?,
        expectedCurrentHead: String?
    ) {
        self.stashID = stashID
        self.branch = branch
        self.expectedCurrentBranch = expectedCurrentBranch
        self.expectedCurrentHead = expectedCurrentHead
    }
}

func stashBranchRetryStateIsSafe(
    _ retry: PersistedStashBranchRetry,
    currentBranch: String?,
    currentHead: String?,
    stashIDs: [String],
    localBranches: [String]
) -> Bool {
    retry.expectedCurrentBranch == currentBranch
        && retry.expectedCurrentHead == currentHead
        && stashIDs.contains(retry.stashID)
        && !localBranches.contains(retry.branch)
}

enum PersistedSubmoduleOperation: String, Codable, Equatable, Sendable {
    case add
    case update
    case sync
    case deinitialize = "deinit"
    case remove
    case setBranch
}

/// Durable context for a standalone SubmodulePanel operation. The request is
/// intentionally independent of the live SwiftUI fields so a failed command
/// can be retried from Operation Log after the window or application reloads.
struct PersistedSubmoduleRetry: Codable, Equatable, Sendable {
    let operation: PersistedSubmoduleOperation
    let url: String?
    let path: String?
    let branch: String?
    let force: Bool?
    let initFlag: Bool?
    let recursive: Bool?
    let remote: Bool?

    init(
        operation: PersistedSubmoduleOperation,
        url: String? = nil,
        path: String? = nil,
        branch: String? = nil,
        force: Bool? = nil,
        initFlag: Bool? = nil,
        recursive: Bool? = nil,
        remote: Bool? = nil
    ) {
        self.operation = operation
        self.url = url
        self.path = path
        self.branch = branch
        self.force = force
        self.initFlag = initFlag
        self.recursive = recursive
        self.remote = remote
    }
}

enum PersistedSubmoduleUndoOperation: String, Codable, Equatable, Sendable {
    case add
    case deinitialize = "deinit"
    case remove
}

/// Expected-state context for a reversible submodule operation. Undo is only
/// offered when the operation can restore the exact gitlink without guessing
/// about .gitmodules or overwriting files created after the original action.
struct PersistedSubmoduleUndo: Codable, Equatable, Sendable {
    let operation: PersistedSubmoduleUndoOperation
    let path: String
    let expectedHeadID: String
    let expectedGitmodulesPresent: Bool
    let expectedGitmodulesContents: String?
    let expectedParentHeadID: String?
    let restoreGitmodulesPresent: Bool?
    let restoreGitmodulesContents: String?

    init(
        operation: PersistedSubmoduleUndoOperation,
        path: String,
        expectedHeadID: String,
        expectedGitmodulesPresent: Bool,
        expectedGitmodulesContents: String?,
        expectedParentHeadID: String? = nil,
        restoreGitmodulesPresent: Bool? = nil,
        restoreGitmodulesContents: String? = nil
    ) {
        self.operation = operation
        self.path = path
        self.expectedHeadID = expectedHeadID
        self.expectedGitmodulesPresent = expectedGitmodulesPresent
        self.expectedGitmodulesContents = expectedGitmodulesContents
        self.expectedParentHeadID = expectedParentHeadID
        self.restoreGitmodulesPresent = restoreGitmodulesPresent
        self.restoreGitmodulesContents = restoreGitmodulesContents
    }
}

/// Expected-state context for undoing a successful commit reword. Reword only
/// changes commit objects, so the narrow ref-only rollback preserves the index
/// and worktree while still refusing stale notifications or a different branch.
struct PersistedRewordUndo: Codable, Equatable, Sendable {
    let initialHeadID: String
    let expectedHeadID: String
    /// Empty means detached HEAD; a non-empty value is the exact local branch.
    let expectedBranch: String
}

struct PersistedShelfPathGroup: Codable, Equatable, Sendable {
    let shelfName: String
    let paths: [String]
}

/// Durable retry scope for IntelliJ's mixed Shelf DeleteProvider action.
/// Active and Recently Deleted members must remain distinguishable when a
/// notification outlives the original tree selection.
struct PersistedShelfDeletePlan: Codable, Equatable, Sendable {
    let activeShelfNames: [String]
    let activePathGroups: [PersistedShelfPathGroup]
    let deletedShelfNames: [String]
    let deletedPathGroups: [PersistedShelfPathGroup]

    init(_ plan: ShelfDeletePlan) {
        activeShelfNames = plan.activeShelfNames
        activePathGroups = plan.activePathGroups.map {
            PersistedShelfPathGroup(shelfName: $0.shelfName, paths: $0.paths)
        }
        deletedShelfNames = plan.deletedShelfNames
        deletedPathGroups = plan.deletedPathGroups.map {
            PersistedShelfPathGroup(shelfName: $0.shelfName, paths: $0.paths)
        }
    }

    var shelfDeletePlan: ShelfDeletePlan {
        ShelfDeletePlan(
            activeShelfNames: activeShelfNames,
            activePathGroups: activePathGroups.map {
                ShelfPathDeleteGroup(shelfName: $0.shelfName, paths: $0.paths)
            },
            deletedShelfNames: deletedShelfNames,
            deletedPathGroups: deletedPathGroups.map {
                ShelfPathDeleteGroup(shelfName: $0.shelfName, paths: $0.paths)
            }
        )
    }
}

/// Durable context for a Log Revert/Cherry-pick that has not reached a
/// terminal result. The initial HEAD is a compare-and-swap guard: a retry is
/// only offered while the repository still points at the commit that the
/// original action observed.
struct PersistedLogApplyRecovery: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case cherryPick
        case revert
    }

    let operation: Operation
    let rootPath: String
    let commitIDs: [String]
    let sessionID: String
    let batchIndex: Int
    let batchCount: Int
    let initialHead: String
    let preserveLocalChanges: Bool
    let emptyPolicyRaw: String
    let appendPublishedSuffix: Bool
    let savePolicyRaw: String
    /// Paths reported by Git when local changes block the apply. Keeping them
    /// in the recovery marker lets a reloaded notification still offer the
    /// same Show Files action as the original operation.
    let affectedPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case operation
        case rootPath
        case commitIDs
        case sessionID
        case batchIndex
        case batchCount
        case initialHead
        case preserveLocalChanges
        case emptyPolicyRaw
        case appendPublishedSuffix
        case savePolicyRaw
        case affectedPaths
    }

    init(
        operation: Operation,
        rootPath: String,
        commitIDs: [String],
        sessionID: String,
        batchIndex: Int,
        batchCount: Int,
        initialHead: String,
        preserveLocalChanges: Bool,
        emptyPolicyRaw: String,
        appendPublishedSuffix: Bool,
        savePolicyRaw: String,
        affectedPaths: [String] = []
    ) {
        self.operation = operation
        self.rootPath = rootPath
        self.commitIDs = commitIDs
        self.sessionID = sessionID
        self.batchIndex = batchIndex
        self.batchCount = batchCount
        self.initialHead = initialHead
        self.preserveLocalChanges = preserveLocalChanges
        self.emptyPolicyRaw = emptyPolicyRaw
        self.appendPublishedSuffix = appendPublishedSuffix
        self.savePolicyRaw = savePolicyRaw
        self.affectedPaths = affectedPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(Operation.self, forKey: .operation)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        commitIDs = try container.decode([String].self, forKey: .commitIDs)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? "legacy:\(rootPath)"
        batchIndex = try container.decodeIfPresent(Int.self, forKey: .batchIndex) ?? 0
        batchCount = max(
            try container.decodeIfPresent(Int.self, forKey: .batchCount) ?? 1,
            1
        )
        initialHead = try container.decode(String.self, forKey: .initialHead)
        preserveLocalChanges = try container.decode(Bool.self, forKey: .preserveLocalChanges)
        emptyPolicyRaw = try container.decode(String.self, forKey: .emptyPolicyRaw)
        appendPublishedSuffix = try container.decode(Bool.self, forKey: .appendPublishedSuffix)
        savePolicyRaw = try container.decode(String.self, forKey: .savePolicyRaw)
        affectedPaths = try container.decodeIfPresent([String].self, forKey: .affectedPaths) ?? []
    }

    func updating(
        preserveLocalChanges: Bool? = nil,
        affectedPaths: [String]? = nil
    ) -> PersistedLogApplyRecovery {
        PersistedLogApplyRecovery(
            operation: operation,
            rootPath: rootPath,
            commitIDs: commitIDs,
            sessionID: sessionID,
            batchIndex: batchIndex,
            batchCount: batchCount,
            initialHead: initialHead,
            preserveLocalChanges: preserveLocalChanges ?? self.preserveLocalChanges,
            emptyPolicyRaw: emptyPolicyRaw,
            appendPublishedSuffix: appendPublishedSuffix,
            savePolicyRaw: savePolicyRaw,
            affectedPaths: affectedPaths ?? self.affectedPaths
        )
    }
}

/// A small, Codable action context for operations that may outlive the
/// current process. Unlike a closure, this request can be carried by a
/// native notification or restored operation history and routed to the
/// matching project/repository window.
struct ArborVCSActionRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case restoreShelf
        case restoreShelfPaths
        case deleteDeletedShelfPaths
        case undoShelfDeletion
        case undoShelfDeletions
        case dropShelf
        case showSavedChanges
        case showLogApplyAffectedFiles
        case showOperationDetails
        case restoreApplyLocalChanges
        case resumeRebase
        case retryShelfBatch
        case retryShelfMemberBatch
        case retryShelfLifecycleBatch
        case retryShelfDeletePlan
        case retryLogApply
        case retryExternalVCSAction
        case openGpgAgentSettings
        case openIdentitySettings
        case rollbackMultiRootCheckout
        case rollbackMultiRootBranchCreate
        case keepMultiRootBranchCreatePartial
        case rollbackMultiRootBranchRename
        case keepMultiRootBranchRenamePartial
        case rollbackMultiRootMerge
        case rollbackMultiRootUpdate
        case rollbackSubmoduleUpdate
        case retrySubmoduleOperation
        case undoSubmoduleOperation
        case rollbackMultiRootReset
        case rollbackResetRecovery
        case keepResetRecovery
        case deleteMultiRootMergeBranch
        case restoreDeletedBranches
        case viewDeletedBranchCommits
        case retryMultiRootOperation
        case retryPush
        case retryPushRecovery
        case retryStashBranch
        case multiRootRebaseRecovery
        case operationRecovery
        case autoFetchRecovery
        case showLogRanges
        case showFindMergedReport
        case rewordCommit
        case undoRewordCommit
        case undoUncommit
        case undoRebase
        case undoLogSelectedChanges
    }

    enum MultiRootRetryOperation: String, Codable, Equatable, Sendable {
        case update
        case fetch
        case pullMerge
        case pullRebase
        case push
        case pushRecovery
        case checkoutUpdate
        case commit
        case pushAfterCommit
        case stage
        case unstage
        case stageAll
        case unstageAll
    }

    enum CheckoutUpdateMode: String, Codable, Sendable {
        case normal
        case smart
        case force
    }

    enum MultiRootPushTagMode: String, Codable, Sendable {
        case all
        case currentBranch
    }

    enum MultiRootRebaseRecoveryAction: String, Codable, Sendable {
        case resume
        case retry
        case stageAndRetry
        case openRecovery
        case rollback
        case keepPartial
        case undo
    }

    enum OperationRecoveryAction: String, Codable, Sendable {
        case continueOperation
        case skip
        case abort
        case openRecovery
    }

    enum AutoFetchRecoveryAction: String, Codable, Sendable {
        case fetchAll
        case retryCheck
        case enable
        case doNotAskAgain
    }

    enum SavedChangesKind: String, Codable, Sendable {
        case stash
        case shelf
    }

    enum ShelfBatchOperation: String, Codable, Sendable {
        case apply
        case pop
        case drop
    }

    enum ShelfLifecycleOperation: String, Codable, Sendable {
        case restoreDeleted
        case deleteDeleted
    }

    enum ShelfMemberBatchOperation: String, Codable, Sendable {
        case unshelve
        case unshelveAndRemove
        case unshelveDeleted
        case unshelveDeletedAndRemove
        case drop
        case deleteDeleted
    }

    let kind: Kind
    let projectPath: String?
    let rootPath: String?
    let shelfName: String
    let shelfPaths: [String]?
    let shelfRestoreTimestamp: Int64?
    let shelfRestoreTimestamps: [String: Int64]?
    let savedChangesKind: SavedChangesKind?
    let savedChangesID: String?
    let shelfNames: [String]?
    let shelfBatchOperation: ShelfBatchOperation?
    let shelfBatchTargetName: String?
    let shelfBatchRemoveApplied: Bool?
    let shelfMemberGroups: [PersistedShelfPathGroup]?
    let shelfMemberBatchOperation: ShelfMemberBatchOperation?
    let shelfMemberBatchTargetName: String?
    let shelfDeletePlan: PersistedShelfDeletePlan?
    let shelfLifecycleOperation: ShelfLifecycleOperation?
    let logApplyRecovery: PersistedLogApplyRecovery?
    let externalVCSAction: RepositoryExternalVCSAction?
    let rebaseBranch: String?
    let checkoutReference: String?
    let checkoutTargets: [PersistedMultiRootCheckoutTarget]?
    let multiRootBranchName: String?
    let multiRootBranchCreateRollbackTargets: [PersistedMultiRootBranchCreateTarget]?
    let multiRootBranchRenameOldName: String?
    let multiRootBranchRenameNewName: String?
    let multiRootBranchRenameRollbackTargets: [PersistedMultiRootBranchRenameRollbackTarget]?
    let multiRootMergeBranchName: String?
    let multiRootMergeRollbackTargets: [PersistedMultiRootMergeRollbackTarget]?
    let multiRootMergeRollbackResultRows: [FeedbackResultRow]?
    let multiRootMergeDeleteBranchName: String?
    let multiRootMergeDeleteRootPaths: [String]?
    let branchDeleteRecoveryTargets: [PersistedBranchDeleteRecoveryTarget]?
    let multiRootRetryOperation: MultiRootRetryOperation?
    let multiRootRetryRootPaths: [String]?
    let multiRootRetryPath: String?
    let multiRootRetryChangePaths: [PersistedMultiRootChangePath]?
    let multiRootRetryUpdateRootPaths: [String]?
    let multiRootRetryRebase: Bool?
    let multiRootRetryRebaseRootPaths: [String]?
    let multiRootRetryLogRevisionRanges: [PersistedLogRevisionRange]?
    let multiRootRetryResultRows: [FeedbackResultRow]?
    let multiRootRetryDetach: Bool?
    let multiRootRetryCheckoutMode: CheckoutUpdateMode?
    let multiRootPushTagMode: MultiRootPushTagMode?
    let multiRootPushSkipHooks: Bool?
    let multiRootPushForce: Bool?
    let multiRootPushForceWithLease: Bool?
    let multiRootCommitRetry: PersistedMultiRootCommitRetry?
    let pushRecovery: PersistedPushRecovery?
    let stashBranchRetry: PersistedStashBranchRetry?
    let submoduleRetry: PersistedSubmoduleRetry?
    let submoduleUndo: PersistedSubmoduleUndo?
    let multiRootRebaseRecoveryAction: MultiRootRebaseRecoveryAction?
    let multiRootRebaseSessionID: String?
    let multiRootRebaseRollbackTargets: [PersistedMultiRootRebaseRollbackTarget]?
    let multiRootUpdateRollbackTargets: [PersistedMultiRootUpdateRollbackTarget]?
    let multiRootResetRollbackTargets: [PersistedMultiRootResetRollbackTarget]?
    let resetRecoveryTargets: [PersistedResetRecoveryTarget]?
    let operationRecoveryAction: OperationRecoveryAction?
    let autoFetchRecoveryAction: AutoFetchRecoveryAction?
    let autoFetchRootPaths: [String]?
    let logRevisionRanges: [PersistedLogRevisionRange]?
    let operationNotificationID: String?
    let findMergedReportID: String?
    let rewordCommitID: String?
    let rewordUndo: PersistedRewordUndo?
    let uncommitCommitID: String?
    let uncommitExpectedHead: String?
    let uncommitExpectedBranch: String?
    let rebaseUndoInitialHead: String?
    let rebaseUndoExpectedHead: String?
    let rebaseUndoBranch: String?
    let rebaseUndoProtectionCommit: String?
    let logSelectedChangesUndoInitialHead: String?
    let logSelectedChangesUndoExpectedHead: String?
    let logSelectedChangesUndoBranch: String?

    init(
        kind: Kind,
        projectPath: String?,
        rootPath: String?,
        shelfName: String,
        shelfPaths: [String]? = nil,
        shelfRestoreTimestamp: Int64? = nil,
        shelfRestoreTimestamps: [String: Int64]? = nil,
        savedChangesKind: SavedChangesKind? = nil,
        savedChangesID: String? = nil,
        shelfNames: [String]? = nil,
        shelfBatchOperation: ShelfBatchOperation? = nil,
        shelfBatchTargetName: String? = nil,
        shelfBatchRemoveApplied: Bool? = nil,
        shelfMemberGroups: [PersistedShelfPathGroup]? = nil,
        shelfMemberBatchOperation: ShelfMemberBatchOperation? = nil,
        shelfMemberBatchTargetName: String? = nil,
        shelfDeletePlan: PersistedShelfDeletePlan? = nil,
        shelfLifecycleOperation: ShelfLifecycleOperation? = nil,
        logApplyRecovery: PersistedLogApplyRecovery? = nil,
        externalVCSAction: RepositoryExternalVCSAction? = nil,
        rebaseBranch: String? = nil,
        checkoutReference: String? = nil,
        checkoutTargets: [PersistedMultiRootCheckoutTarget]? = nil,
        multiRootBranchName: String? = nil,
        multiRootBranchCreateRollbackTargets: [PersistedMultiRootBranchCreateTarget]? = nil,
        multiRootBranchRenameOldName: String? = nil,
        multiRootBranchRenameNewName: String? = nil,
        multiRootBranchRenameRollbackTargets: [PersistedMultiRootBranchRenameRollbackTarget]? = nil,
        multiRootMergeBranchName: String? = nil,
        multiRootMergeRollbackTargets: [PersistedMultiRootMergeRollbackTarget]? = nil,
        multiRootMergeRollbackResultRows: [FeedbackResultRow]? = nil,
        multiRootMergeDeleteBranchName: String? = nil,
        multiRootMergeDeleteRootPaths: [String]? = nil,
        branchDeleteRecoveryTargets: [PersistedBranchDeleteRecoveryTarget]? = nil,
        multiRootRetryOperation: MultiRootRetryOperation? = nil,
        multiRootRetryRootPaths: [String]? = nil,
        multiRootRetryPath: String? = nil,
        multiRootRetryChangePaths: [PersistedMultiRootChangePath]? = nil,
        multiRootRetryUpdateRootPaths: [String]? = nil,
        multiRootRetryRebase: Bool? = nil,
        multiRootRetryRebaseRootPaths: [String]? = nil,
        multiRootRetryLogRevisionRanges: [PersistedLogRevisionRange]? = nil,
        multiRootRetryResultRows: [FeedbackResultRow]? = nil,
        multiRootRetryDetach: Bool? = nil,
        multiRootRetryCheckoutMode: CheckoutUpdateMode? = nil,
        multiRootPushTagMode: MultiRootPushTagMode? = nil,
        multiRootPushSkipHooks: Bool? = nil,
        multiRootPushForce: Bool? = nil,
        multiRootPushForceWithLease: Bool? = nil,
        multiRootCommitRetry: PersistedMultiRootCommitRetry? = nil,
        pushRecovery: PersistedPushRecovery? = nil,
        stashBranchRetry: PersistedStashBranchRetry? = nil,
        submoduleRetry: PersistedSubmoduleRetry? = nil,
        submoduleUndo: PersistedSubmoduleUndo? = nil,
        multiRootRebaseRecoveryAction: MultiRootRebaseRecoveryAction? = nil,
        multiRootRebaseSessionID: String? = nil,
        multiRootRebaseRollbackTargets: [PersistedMultiRootRebaseRollbackTarget]? = nil,
        multiRootUpdateRollbackTargets: [PersistedMultiRootUpdateRollbackTarget]? = nil,
        multiRootResetRollbackTargets: [PersistedMultiRootResetRollbackTarget]? = nil,
        resetRecoveryTargets: [PersistedResetRecoveryTarget]? = nil,
        operationRecoveryAction: OperationRecoveryAction? = nil,
        autoFetchRecoveryAction: AutoFetchRecoveryAction? = nil,
        autoFetchRootPaths: [String]? = nil,
        logRevisionRanges: [PersistedLogRevisionRange]? = nil,
        operationNotificationID: String? = nil,
        findMergedReportID: String? = nil,
        rewordCommitID: String? = nil,
        rewordUndo: PersistedRewordUndo? = nil,
        uncommitCommitID: String? = nil,
        uncommitExpectedHead: String? = nil,
        uncommitExpectedBranch: String? = nil,
        rebaseUndoInitialHead: String? = nil,
        rebaseUndoExpectedHead: String? = nil,
        rebaseUndoBranch: String? = nil,
        rebaseUndoProtectionCommit: String? = nil,
        logSelectedChangesUndoInitialHead: String? = nil,
        logSelectedChangesUndoExpectedHead: String? = nil,
        logSelectedChangesUndoBranch: String? = nil
    ) {
        self.kind = kind
        self.projectPath = projectPath
        self.rootPath = rootPath
        self.shelfName = shelfName
        self.shelfPaths = shelfPaths
        self.shelfRestoreTimestamp = shelfRestoreTimestamp
        self.shelfRestoreTimestamps = shelfRestoreTimestamps
        self.savedChangesKind = savedChangesKind
        self.savedChangesID = savedChangesID
        self.shelfNames = shelfNames
        self.shelfBatchOperation = shelfBatchOperation
        self.shelfBatchTargetName = shelfBatchTargetName
        self.shelfBatchRemoveApplied = shelfBatchRemoveApplied
        self.shelfMemberGroups = shelfMemberGroups
        self.shelfMemberBatchOperation = shelfMemberBatchOperation
        self.shelfMemberBatchTargetName = shelfMemberBatchTargetName
        self.shelfDeletePlan = shelfDeletePlan
        self.shelfLifecycleOperation = shelfLifecycleOperation
        self.logApplyRecovery = logApplyRecovery
        self.externalVCSAction = externalVCSAction
        self.rebaseBranch = rebaseBranch
        self.checkoutReference = checkoutReference
        self.checkoutTargets = checkoutTargets
        self.multiRootBranchName = multiRootBranchName
        self.multiRootBranchCreateRollbackTargets = multiRootBranchCreateRollbackTargets
        self.multiRootBranchRenameOldName = multiRootBranchRenameOldName
        self.multiRootBranchRenameNewName = multiRootBranchRenameNewName
        self.multiRootBranchRenameRollbackTargets = multiRootBranchRenameRollbackTargets
        self.multiRootMergeBranchName = multiRootMergeBranchName
        self.multiRootMergeRollbackTargets = multiRootMergeRollbackTargets
        self.multiRootMergeRollbackResultRows = multiRootMergeRollbackResultRows
        self.multiRootMergeDeleteBranchName = multiRootMergeDeleteBranchName
        self.multiRootMergeDeleteRootPaths = multiRootMergeDeleteRootPaths
        self.branchDeleteRecoveryTargets = branchDeleteRecoveryTargets
        self.multiRootRetryOperation = multiRootRetryOperation
        self.multiRootRetryRootPaths = multiRootRetryRootPaths
        self.multiRootRetryPath = multiRootRetryPath
        self.multiRootRetryChangePaths = multiRootRetryChangePaths
        self.multiRootRetryUpdateRootPaths = multiRootRetryUpdateRootPaths
        self.multiRootRetryRebase = multiRootRetryRebase
        self.multiRootRetryRebaseRootPaths = multiRootRetryRebaseRootPaths
        self.multiRootRetryLogRevisionRanges = multiRootRetryLogRevisionRanges
        self.multiRootRetryResultRows = multiRootRetryResultRows
        self.multiRootRetryDetach = multiRootRetryDetach
        self.multiRootRetryCheckoutMode = multiRootRetryCheckoutMode
        self.multiRootPushTagMode = multiRootPushTagMode
        self.multiRootPushSkipHooks = multiRootPushSkipHooks
        self.multiRootPushForce = multiRootPushForce
        self.multiRootPushForceWithLease = multiRootPushForceWithLease
        self.multiRootCommitRetry = multiRootCommitRetry
        self.pushRecovery = pushRecovery
        self.stashBranchRetry = stashBranchRetry
        self.submoduleRetry = submoduleRetry
        self.submoduleUndo = submoduleUndo
        self.multiRootRebaseRecoveryAction = multiRootRebaseRecoveryAction
        self.multiRootRebaseSessionID = multiRootRebaseSessionID
        self.multiRootRebaseRollbackTargets = multiRootRebaseRollbackTargets
        self.multiRootUpdateRollbackTargets = multiRootUpdateRollbackTargets
        self.multiRootResetRollbackTargets = multiRootResetRollbackTargets
        self.resetRecoveryTargets = resetRecoveryTargets
        self.operationRecoveryAction = operationRecoveryAction
        self.autoFetchRecoveryAction = autoFetchRecoveryAction
        self.autoFetchRootPaths = autoFetchRootPaths
        self.logRevisionRanges = logRevisionRanges
        self.operationNotificationID = operationNotificationID
        self.findMergedReportID = findMergedReportID
        self.rewordCommitID = rewordCommitID
        self.rewordUndo = rewordUndo
        self.uncommitCommitID = uncommitCommitID
        self.uncommitExpectedHead = uncommitExpectedHead
        self.uncommitExpectedBranch = uncommitExpectedBranch
        self.rebaseUndoInitialHead = rebaseUndoInitialHead
        self.rebaseUndoExpectedHead = rebaseUndoExpectedHead
        self.rebaseUndoBranch = rebaseUndoBranch
        self.rebaseUndoProtectionCommit = rebaseUndoProtectionCommit
        self.logSelectedChangesUndoInitialHead = logSelectedChangesUndoInitialHead
        self.logSelectedChangesUndoExpectedHead = logSelectedChangesUndoExpectedHead
        self.logSelectedChangesUndoBranch = logSelectedChangesUndoBranch
    }
}

struct ProjectCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.arborRepositoryIsShallow) private var isShallowRepository
    @FocusedValue(\.arborVCSActionContext) private var actionContext
    @FocusedValue(\.arborVCSOperationContext) private var operationContext

    var body: some Commands {
        CommandMenu("File") {
            Button("Open Project…") {
                NotificationCenter.default.post(name: .arborOpenProjectPanel, object: nil)
            }
            Button("Initialize Git Repository…") {
                NotificationCenter.default.post(name: .arborInitProjectPanel, object: nil)
            }
            Button("Clone Git Repository…") {
                NotificationCenter.default.post(name: .arborCloneProjectDialog, object: nil)
            }
            Menu("Open Recent Project") {
                let recent = UserDefaults.standard.stringArray(forKey: "lastOpenedPaths") ?? []
                if recent.isEmpty {
                    Text("No Recent Projects")
                } else {
                    ForEach(recent, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            openWindow(value: path)
                        }
                    }
                }
            }
        }
        CommandMenu("VCS") {
            Menu("Git") {
                Button("Search Everywhere…") { postVCS(.searchEverywhere) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(!actionEnabled(.searchEverywhere))
                Button("Quick Git Actions…") { postVCS(.quickActions) }
                    .keyboardShortcut("q", modifiers: [.command, .option])
                    .disabled(!actionEnabled(.quickActions))
                Menu("Tool Windows") {
                    Button("Show Log") { postVCS(.showLog) }
                        .keyboardShortcut("9", modifiers: [.command])
                        .disabled(!actionEnabled(.showLog))
                    Button("Show Log in New Window") { openExternalLogWindow() }
                        .disabled(!actionEnabled(.showExternalLog))
                    Button("Operation Log") { postVCS(.showOperations) }
                        .disabled(!actionEnabled(.showOperations))
                    Button("Git Roots") { postVCS(.showGitRoots) }
                        .disabled(!actionEnabled(.showGitRoots))
                    Button("Git Console") { postVCS(.showGitConsole) }
                        .disabled(!actionEnabled(.showGitConsole))
                }
                Button("Refresh Git State") { postVCS(.refresh) }
                    .disabled(!actionEnabled(.refresh))
                Divider()
                Button("Update Project") { postVCS(.update) }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(!actionEnabled(.update))
                Button("Reset Head…") { postVCS(.reset) }
                    .disabled(!actionEnabled(.reset))
                Button("Reset to Remote Branch…") { postVCS(.resetToRemoteBranch) }
                    .disabled(!actionEnabled(.resetToRemoteBranch))
                Button("Commit…") { postVCS(.commit) }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!actionEnabled(.commit))
                Button("Show Staging Area") { postVCS(.showStagingArea) }
                    .disabled(!actionEnabled(.showStagingArea))
                Button("Commit and Push…") { postVCS(.commitAndPush) }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(!actionEnabled(.commitAndPush))
                Button("Push…") { postVCS(.push) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!actionEnabled(.push))
                Button("Fetch") { postVCS(.fetch) }
                    .disabled(!actionEnabled(.fetch))
                Button("Fetch All") { postVCS(.fetchAll) }
                    .disabled(!actionEnabled(.fetchAll))
                Button("Prune Remote Branches") { postVCS(.fetchPrune) }
                    .disabled(!actionEnabled(.fetchPrune))
                if isShallowRepository == true {
                    Button("Fetch Full History…") { postVCS(.fetchUnshallow) }
                        .disabled(!actionEnabled(.fetchUnshallow))
                }
                Button("Pull…") { postVCS(.pull) }
                    .disabled(!actionEnabled(.pull))
                Divider()
                Menu("Local Changes") {
                    Button("Shelve…") { postVCS(.shelve) }
                        .disabled(!actionEnabled(.shelve))
                    Button("Show Shelf") { postVCS(.showShelf) }
                        .disabled(!actionEnabled(.showShelf))
                    Button("Show Stash") { postVCS(.showStash) }
                        .disabled(!actionEnabled(.showStash))
                    Button("Stash…") { postVCS(.stash) }
                        .disabled(!actionEnabled(.stash))
                    Button("Unstash…") { postVCS(.unstash) }
                        .disabled(!actionEnabled(.unstash))
                    Button("Revert Selected Changes…", role: .destructive) {
                        postVCS(.revertSelectedChanges)
                    }
                    .disabled(!actionEnabled(.revertSelectedChanges))
                }
                Divider()
                Button("Apply Patch…") { postVCS(.applyPatch) }
                    .disabled(!actionEnabled(.applyPatch))
                Button("Apply Patch from Clipboard…") { postVCS(.applyPatchFromClipboard) }
                    .disabled(!actionEnabled(.applyPatchFromClipboard))
                if actionContext?.selectedFileAction != nil {
                    Menu("File Actions") {
                        Button("Checkin Files…") { postVCS(.fileCheckin) }
                            .disabled(!actionEnabled(.fileCheckin))
                        Button("Add") { postVCS(.fileAdd) }
                            .disabled(!actionEnabled(.fileAdd))
                        Divider()
                        Button("Annotate") { postVCS(.fileAnnotate) }
                            .disabled(!actionEnabled(.fileAnnotate))
                        Button("Compare with HEAD") { postVCS(.fileCompareSameVersion) }
                            .disabled(!actionEnabled(.fileCompareSameVersion))
                        Button("Compare with Selected Revision…") {
                            postVCS(.fileCompareSelectedRevision)
                        }
                        .disabled(!actionEnabled(.fileCompareSelectedRevision))
                        Button("Compare with Branch or Tag…") {
                            postVCS(.fileCompareWithBranch)
                        }
                        .disabled(!actionEnabled(.fileCompareWithBranch))
                        Button("Show File History") { postVCS(.fileHistory) }
                            .disabled(!actionEnabled(.fileHistory))
                    }
                }
                if isArborVCSActionVisible(.merge, in: actionContext) {
                    Button("Merge…") { postVCS(.merge) }
                        .disabled(!actionEnabled(.merge))
                }
                if isArborVCSActionVisible(.rebase, in: actionContext) {
                    Button("Rebase…") { postVCS(.rebase) }
                        .disabled(!actionEnabled(.rebase))
                }
                if let operationContext {
                    let actions = gitMainMenuOperationActions(
                        for: operationContext.kind,
                        hasConflicts: operationContext.hasConflicts
                    )
                    if !actions.isEmpty {
                        Divider()
                        if operationContext.kind == .rebase {
                            Menu("Rebase in Progress") {
                                ForEach(actions) { action in
                                    Button(action.title) {
                                        postOperationRecovery(
                                            action.recoveryAction,
                                            rootPath: operationContext.rootPath
                                        )
                                    }
                                }
                            }
                        } else {
                            ForEach(actions) { action in
                                Button(action.title) {
                                    postOperationRecovery(
                                        action.recoveryAction,
                                        rootPath: operationContext.rootPath
                                    )
                                }
                            }
                        }
                    }
                }
                Button("Resolve Conflicts") { postVCS(.resolveConflicts) }
                    .disabled(!actionEnabled(.resolveConflicts))
                if actionContext?.selectedResolvedConflictPath != nil {
                    Button("Revert Resolved") { postVCS(.revertResolved) }
                        .disabled(!actionEnabled(.revertResolved))
                }
                Button("New Branch…") { postVCS(.newBranch) }
                    .disabled(!actionEnabled(.newBranch))
                Button("New Tag…") { postVCS(.newTag) }
                    .disabled(!actionEnabled(.newTag))
                Button("Worktrees…") { postVCS(.worktrees) }
                    .disabled(!actionEnabled(.worktrees))
                Button("Branches…") { postVCS(.branches) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!actionEnabled(.branches))
                Divider()
                Button("Configure Remotes…") { postVCS(.configureRemotes) }
                    .disabled(!actionEnabled(.configureRemotes))
                Button("Clone Git Repository…") {
                    NotificationCenter.default.post(name: .arborCloneProjectDialog, object: nil)
                }
            }
        }
        CommandGroup(after: .appSettings) {
            SettingsLink {
                Text("Language…")
            }
        }
    }

    private func postVCS(_ action: ArborVCSAction) {
        NotificationCenter.default.post(name: .arborVCSAction, object: action.rawValue)
    }

    private func postOperationRecovery(
        _ action: ArborVCSActionRequest.OperationRecoveryAction,
        rootPath: String
    ) {
        NotificationCenter.default.post(
            name: .arborVCSAction,
            object: ArborVCSActionRequest(
                kind: .operationRecovery,
                projectPath: actionContext?.projectPath,
                rootPath: rootPath,
                shelfName: "",
                operationRecoveryAction: action
            )
        )
    }

    private func actionEnabled(_ action: ArborVCSAction) -> Bool {
        isArborVCSActionEnabled(action, in: actionContext)
    }

    private func openExternalLogWindow() {
        guard let projectPath = actionContext?.projectPath else { return }
        guard let request = chooseExternalLogWindowRequest(for: projectPath) else { return }
        openWindow(id: "git-log", value: request)
    }
}
