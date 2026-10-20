import Foundation

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
