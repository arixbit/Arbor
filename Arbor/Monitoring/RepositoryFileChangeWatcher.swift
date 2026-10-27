import CoreServices
import SwiftUI


enum RepositoryFileChangeClassifier {
    /// Normalizes and coalesces paths from one FSEventStream callback. A path
    /// is considered a directory when any event for it carries the directory
    /// flag; this handles a file-system rename sequence that reports the same
    /// path more than once with different flags.
    static func classify(
        rootPath: String,
        paths: [String],
        flags: [UInt32]
    ) -> [RepositoryDirtyPath] {
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        var pathInfo: [String: (isDirectory: Bool, kind: RepositoryDirtyChangeKind)] = [:]
        for (index, rawPath) in paths.enumerated() {
            let url: URL
            if rawPath.hasPrefix("/") {
                url = URL(fileURLWithPath: rawPath).standardizedFileURL
            } else {
                url = rootURL.appendingPathComponent(rawPath).standardizedFileURL
            }
            let isDirectory = index < flags.count
                && (flags[index] & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
            let kind = index < flags.count
                ? changeKind(for: flags[index])
                : .modified
            if let previous = pathInfo[url.path] {
                pathInfo[url.path] = (
                    isDirectory: previous.isDirectory || isDirectory,
                    kind: .merging(previous.kind, kind)
                )
            } else {
                pathInfo[url.path] = (isDirectory: isDirectory, kind: kind)
            }
        }
        return pathInfo.map { path, info in
            RepositoryDirtyPath(
                path: path,
                isDirectory: info.isDirectory,
                kind: info.kind
            )
        }.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private static func changeKind(for flags: UInt32) -> RepositoryDirtyChangeKind {
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { return .renamed }
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { return .removed }
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { return .created }
        return .modified
    }
}

private final class RepositoryFileChangeCallbackContext {
    weak var watcher: RepositoryFileChangeWatcher?
    let scope: RepositoryChangeScope
    let rootPath: String
    let excludedRootPaths: [String]

    init(
        watcher: RepositoryFileChangeWatcher,
        scope: RepositoryChangeScope,
        rootPath: String,
        excludedRootPaths: [String] = []
    ) {
        self.watcher = watcher
        self.scope = scope
        self.rootPath = rootPath
        self.excludedRootPaths = excludedRootPaths
    }
}

final class RepositoryFileChangeWatcher {
    private let workdir: String
    private let gitDir: String
    private let metadataRootPaths: [String]
    private let excludedWorktreePaths: [String]
    private let onChange: (RepositoryChangeEvent) -> Void
    private let queue = DispatchQueue(label: "com.arbor.repository-file-monitor", qos: .utility)
    private var streams: [FSEventStreamRef] = []
    private var callbackContexts: [RepositoryFileChangeCallbackContext] = []
    private var pendingScopes: RepositoryChangeScope = []
    private var pendingDirtyPaths: [String: RepositoryDirtyPath] = [:]
    private var deliveryScheduled = false
    private var stopped = false
    private var fileSnapshots: [String: RepositoryFileSnapshot] = [:]
    /// Reverse index so an unpaired rename can find its old endpoint from the
    /// cache instead of walking the worktree.
    private var snapshotPathsByIdentity: [String: Set<String>] = [:]
    private var snapshotsSeeded = false
    init(
        workdir: String,
        gitDir: String,
        excludedWorktreePaths: [String] = [],
        onChange: @escaping (RepositoryChangeEvent) -> Void
    ) {
        self.workdir = URL(fileURLWithPath: workdir).standardizedFileURL.path
        self.gitDir = URL(fileURLWithPath: gitDir).standardizedFileURL.path
        self.metadataRootPaths = repositoryMetadataRootPaths(gitDir: self.gitDir)
        self.excludedWorktreePaths = excludedWorktreePaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.onChange = onChange
    }

    func start() {
        let worktreeContext = RepositoryFileChangeCallbackContext(
            watcher: self,
            scope: .worktree,
            rootPath: workdir,
            excludedRootPaths: excludedWorktreePaths
        )
        callbackContexts = [worktreeContext]

        createStream(path: workdir, context: worktreeContext)
        seedFileSnapshots()
        for metadataRootPath in metadataRootPaths where metadataRootPath != workdir {
            let metadataContext = RepositoryFileChangeCallbackContext(
                watcher: self,
                scope: .gitMetadata,
                rootPath: metadataRootPath
            )
            callbackContexts.append(metadataContext)
            createStream(path: metadataRootPath, context: metadataContext)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            for stream in self.streams {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            self.streams.removeAll()
            self.callbackContexts.removeAll()
        }
    }

    /// Seeds the identity cache once per watched root. The walk is bounded by
    /// both an entry budget and a deadline: a rename that involves a file the
    /// cache never saw stays unpaired, which the refresh path already treats
    /// conservatively, so a larger budget buys latency, not correctness.
    private func seedFileSnapshots() {
        guard !snapshotsSeeded else { return }
        snapshotsSeeded = true
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let snapshots = repositoryFileSnapshots(
                rootPath: self.workdir,
                excludedRootPaths: self.excludedWorktreePaths,
                maxEntries: 20_000,
                deadline: Date().addingTimeInterval(0.25)
            )
            guard !self.stopped else { return }
            self.fileSnapshots = snapshots
            self.snapshotPathsByIdentity = Dictionary(
                grouping: snapshots,
                by: { $0.value.identity }
            ).mapValues { Set($0.map(\.key)) }
        }
    }

    /// Recovers the old endpoint of FSEvents' unpaired renames from the cached
    /// identities. Rebuilding a whole-worktree snapshot here made every save
    /// that goes through a temp-file rename walk the entire repository, which
    /// pinned a CPU core on large working trees.
    private func resolveRenamePairs(
        in dirtyPaths: [RepositoryDirtyPath]
    ) -> [RepositoryDirtyPath] {
        var affected = Set(dirtyPaths.map(\.path))
        for path in dirtyPaths {
            if let oldPath = path.oldPath {
                affected.insert(oldPath)
            }
        }
        for path in dirtyPaths where path.kind == .renamed && path.oldPath == nil {
            guard let snapshot = repositoryFileSnapshot(atPath: path.path),
                  let candidates = snapshotPathsByIdentity[snapshot.identity] else {
                continue
            }
            affected.formUnion(candidates)
        }

        var previous: [String: RepositoryFileSnapshot] = [:]
        var current: [String: RepositoryFileSnapshot] = [:]
        for path in affected {
            if let snapshot = fileSnapshots[path] {
                previous[path] = snapshot
            }
            updateFileSnapshot(atPath: path)
            if let snapshot = fileSnapshots[path] {
                current[path] = snapshot
            }
        }

        return repositoryPairRenameEvents(
            dirtyPaths: dirtyPaths,
            previous: previous,
            current: current
        )
    }

    private func updateFileSnapshot(atPath path: String) {
        let cached = fileSnapshots[path]
        guard let snapshot = repositoryFileSnapshot(atPath: path) else {
            guard let cached else { return }
            fileSnapshots.removeValue(forKey: path)
            snapshotPathsByIdentity[cached.identity]?.remove(path)
            if snapshotPathsByIdentity[cached.identity]?.isEmpty == true {
                snapshotPathsByIdentity.removeValue(forKey: cached.identity)
            }
            return
        }
        guard cached?.identity != snapshot.identity else { return }
        if let cached {
            snapshotPathsByIdentity[cached.identity]?.remove(path)
            if snapshotPathsByIdentity[cached.identity]?.isEmpty == true {
                snapshotPathsByIdentity.removeValue(forKey: cached.identity)
            }
        }
        fileSnapshots[path] = snapshot
        snapshotPathsByIdentity[snapshot.identity, default: []].insert(path)
    }

    /// Used by the index revision fallback when a filesystem event is not
    /// delivered (for example, during an atomic index replacement).
    func notify(scope: RepositoryChangeScope) {
        queue.async { [weak self] in
            self?.schedule(scope, paths: [])
        }
    }

    private func createStream(
        path: String,
        context callbackContext: RepositoryFileChangeCallbackContext
    ) {
        guard FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            repositoryFileChangeCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        streams.append(stream)
    }

    fileprivate func eventReceived(scope: RepositoryChangeScope, paths: [RepositoryDirtyPath]) {
        // FSEventStream callbacks run on `queue`, so all debounce state stays
        // serialized without additional locks.
        schedule(scope, paths: paths)
    }

    private func schedule(_ scope: RepositoryChangeScope, paths: [RepositoryDirtyPath]) {
        guard !stopped else { return }
        pendingScopes.formUnion(scope)
        for path in paths {
            let key = repositoryEventKey(path.path)
            if let previous = pendingDirtyPaths[key] {
                pendingDirtyPaths[key] = mergedRepositoryDirtyPath(previous, path)
            } else {
                pendingDirtyPaths[key] = path
            }
        }
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            guard let self else { return }
            let scopes = self.pendingScopes
            let rawDirtyPaths = self.pendingDirtyPaths.values.sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
                return $0.kind.rawValue < $1.kind.rawValue
            }
            let dirtyPaths: [RepositoryDirtyPath]
            let needsRenamePairing = scopes.contains(.worktree)
                && rawDirtyPaths.contains {
                    $0.kind == .renamed && $0.oldPath == nil
                }
            if needsRenamePairing {
                dirtyPaths = self.resolveRenamePairs(in: rawDirtyPaths)
            } else {
                dirtyPaths = rawDirtyPaths
            }
            self.pendingScopes = []
            self.pendingDirtyPaths = [:]
            self.deliveryScheduled = false
            guard !self.stopped, !scopes.isEmpty else { return }
            DispatchQueue.main.async {
                self.onChange(
                    RepositoryChangeEvent(
                        repositoryPath: self.workdir,
                        scopes: scopes,
                        dirtyPaths: dirtyPaths
                    )
                )
            }
        }
    }
}

private func repositoryFileChangeCallback(
    _ stream: FSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let context = Unmanaged<RepositoryFileChangeCallbackContext>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    guard context.watcher != nil, numEvents > 0 else { return }
    // UseCFTypes above makes eventPaths a CFArrayRef. Without that flag the
    // callback receives a raw C string array and bridging it as NSArray would
    // crash as soon as the first filesystem event arrived.
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    let flags = (0..<numEvents).map { eventFlags[$0] }
    let dirtyPaths = RepositoryFileChangeClassifier.classify(
        rootPath: context.rootPath,
        paths: paths,
        flags: flags
    ).filter { dirtyPath in
        !repositoryShouldIgnoreGeneratedWorktreeEvent(
            scope: context.scope,
            path: dirtyPath.path,
            rootPath: context.rootPath,
            kind: dirtyPath.kind,
            oldPath: dirtyPath.oldPath
        )
    }.filter { dirtyPath in
        !repositoryShouldIgnoreGitMetadataEvent(
            scope: context.scope,
            path: dirtyPath.path
        )
    }.filter { dirtyPath in
        !context.excludedRootPaths.contains { excludedPath in
            let prefix = excludedPath.hasSuffix("/") ? excludedPath : "\(excludedPath)/"
            return dirtyPath.path == excludedPath || dirtyPath.path.hasPrefix(prefix)
        }
    }
    guard !dirtyPaths.isEmpty else { return }
    context.watcher?.eventReceived(scope: context.scope, paths: dirtyPaths)
}
