import CoreServices
import SwiftUI

/// The subset of repository changes that needs a broader cache refresh.
struct RepositoryChangeScope: OptionSet, Sendable {
    let rawValue: Int

    static let worktree = RepositoryChangeScope(rawValue: 1 << 0)
    static let gitMetadata = RepositoryChangeScope(rawValue: 1 << 1)
}

enum RepositoryDirtyChangeKind: String, Hashable, Sendable, Equatable {
    case created
    case modified
    case removed
    case renamed

    static func merging(
        _ lhs: RepositoryDirtyChangeKind,
        _ rhs: RepositoryDirtyChangeKind
    ) -> RepositoryDirtyChangeKind {
        if lhs == rhs { return lhs }
        if lhs == .renamed || rhs == .renamed { return .renamed }
        if (lhs == .created && rhs == .removed)
            || (lhs == .removed && rhs == .created) {
            return .renamed
        }
        if (lhs == .created && rhs == .modified)
            || (lhs == .modified && rhs == .created) {
            return .created
        }
        if (lhs == .removed && rhs == .modified)
            || (lhs == .modified && rhs == .removed) {
            return .removed
        }
        return .modified
    }
}

/// A path reported by the recursive VFS/FSEvents watcher. Keeping the path
/// and its change kind lets a later dirty-scope classifier distinguish create,
/// delete, rename, and ordinary content updates without rescanning history.
struct RepositoryDirtyPath: Hashable, Sendable, Equatable {
    let path: String
    /// The previous endpoint for a uniquely paired rename. FSEvents does not
    /// provide this directly; the watcher fills it only when filesystem
    /// identity proves the old and new paths refer to the same item.
    let oldPath: String?
    let isDirectory: Bool
    let kind: RepositoryDirtyChangeKind

    init(
        path: String,
        isDirectory: Bool,
        kind: RepositoryDirtyChangeKind = .modified,
        oldPath: String? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.isDirectory = isDirectory
        self.kind = kind
    }
}

struct RepositoryChangeEvent: Sendable, Equatable {
    let repositoryPath: String
    let scopes: RepositoryChangeScope
    let dirtyPaths: [RepositoryDirtyPath]

    init(
        repositoryPath: String = "",
        scopes: RepositoryChangeScope,
        dirtyPaths: [RepositoryDirtyPath]
    ) {
        self.repositoryPath = repositoryPath
        self.scopes = scopes
        self.dirtyPaths = dirtyPaths
    }
}

private func repositoryEventKey(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func isRepositoryPath(_ path: String, isSameOrDescendantOf ancestor: String) -> Bool {
    guard path != ancestor else { return true }
    if ancestor == "/" {
        return path.hasPrefix("/")
    }
    return path.hasPrefix(ancestor + "/")
}

extension RepositoryChangeEvent {
    /// Merge two batches for one Git root before they reach the refresh
    /// pipeline. Conflicting rename origins deliberately become unpaired so
    /// the caller keeps the conservative full-refresh behavior.
    func merged(with other: RepositoryChangeEvent) -> RepositoryChangeEvent? {
        guard repositoryEventKey(repositoryPath) == repositoryEventKey(other.repositoryPath) else {
            return nil
        }

        var paths: [String: RepositoryDirtyPath] = [:]
        for incoming in dirtyPaths + other.dirtyPaths {
            let key = repositoryEventKey(incoming.path)
            guard let previous = paths[key] else {
                paths[key] = incoming
                continue
            }
            paths[key] = mergedRepositoryDirtyPath(previous, incoming)
        }

        return RepositoryChangeEvent(
            repositoryPath: repositoryPath,
            scopes: scopes.union(other.scopes),
            dirtyPaths: paths.values.sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        )
    }
}

private func mergedRepositoryDirtyPath(
    _ previous: RepositoryDirtyPath,
    _ incoming: RepositoryDirtyPath
) -> RepositoryDirtyPath {
    let oldPath: String?
    switch (previous.oldPath, incoming.oldPath) {
    case let (lhs?, rhs?) where repositoryEventKey(lhs) != repositoryEventKey(rhs):
        oldPath = nil
    case let (lhs?, _):
        oldPath = lhs
    case let (_, rhs?):
        oldPath = rhs
    default:
        oldPath = nil
    }
    return RepositoryDirtyPath(
        path: previous.path,
        isDirectory: previous.isDirectory || incoming.isDirectory,
        kind: RepositoryDirtyChangeKind.merging(previous.kind, incoming.kind),
        oldPath: oldPath
    )
}

/// The ContentView-side equivalent of IntelliJ's packed dirty scope: events
/// are merged per Git root, then drained as one refresh request.
struct RepositoryChangeBatch: Equatable, Sendable {
    private var events: [String: RepositoryChangeEvent] = [:]

    var isEmpty: Bool { events.isEmpty }

    mutating func insert(_ event: RepositoryChangeEvent) {
        let key = repositoryEventKey(event.repositoryPath)
        if let previous = events[key], let merged = previous.merged(with: event) {
            events[key] = merged
        } else {
            events[key] = event
        }
    }

    mutating func drain() -> [RepositoryChangeEvent] {
        let result = events.values.sorted {
            repositoryEventKey($0.repositoryPath) < repositoryEventKey($1.repositoryPath)
        }
        events.removeAll()
        return result
    }

    mutating func removeAll() {
        events.removeAll()
    }
}

/// Root-scoped lifecycle for the GitVFSListener action phase. IntelliJ first
/// packs VFS events, then consumes one action batch per Git root; a later event
/// stays pending until the earlier Add/Remove/force-move operation finishes.
/// Keeping this separate from the visible dirty-scope ledger prevents two
/// status snapshots from racing into two confirmation dialogs or Git writes.
struct RepositoryExternalVCSActionTicket: Equatable, Sendable {
    let repositoryPath: String
    let generation: UInt64
    let event: RepositoryChangeEvent
}

struct RepositoryExternalVCSActionManager: Equatable, Sendable {
    private var pending: [String: RepositoryChangeEvent] = [:]
    private var inProgress: [String: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    var hasPendingActions: Bool { !pending.isEmpty }
    var hasInProgressActions: Bool { !inProgress.isEmpty }

    mutating func enqueue(_ event: RepositoryChangeEvent) {
        let root = repositoryEventKey(event.repositoryPath)
        if let previous = pending[root], let merged = previous.merged(with: event) {
            pending[root] = merged
        } else {
            pending[root] = event
        }
    }

    mutating func begin(repositoryPath: String) -> RepositoryExternalVCSActionTicket? {
        let root = repositoryEventKey(repositoryPath)
        guard inProgress[root] == nil,
              let event = pending.removeValue(forKey: root) else {
            return nil
        }
        nextGeneration &+= 1
        inProgress[root] = nextGeneration
        return RepositoryExternalVCSActionTicket(
            repositoryPath: root,
            generation: nextGeneration,
            event: event
        )
    }

    @discardableResult
    mutating func finish(_ ticket: RepositoryExternalVCSActionTicket) -> Bool {
        let root = repositoryEventKey(ticket.repositoryPath)
        guard inProgress[root] == ticket.generation else { return false }
        inProgress.removeValue(forKey: root)
        return true
    }

    mutating func removeAll() {
        pending.removeAll()
        inProgress.removeAll()
    }
}

/// Serializes the visible-status portion of refreshes without making every
/// Git operation wait for the previous background task. A refresh that starts
/// while another one is still computing cannot safely merge against the old
/// `entries` snapshot, so it is promoted to a full status walk. Only the
/// newest ticket may publish results; this mirrors IntelliJ's packed dirty
/// scope consumption and prevents an older batch from restoring stale rows.
struct RepositoryRefreshTicket: Equatable, Sendable {
    let generation: UInt64
    let usesIncrementalStatus: Bool
}

struct RepositoryRefreshGate: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var hasInFlightRefresh = false

    mutating func begin(usesIncrementalStatus requested: Bool) -> RepositoryRefreshTicket {
        generation &+= 1
        let usesIncrementalStatus = requested && !hasInFlightRefresh
        hasInFlightRefresh = true
        return RepositoryRefreshTicket(
            generation: generation,
            usesIncrementalStatus: usesIncrementalStatus
        )
    }

    func isCurrent(_ ticket: RepositoryRefreshTicket) -> Bool {
        ticket.generation == generation
    }

    mutating func finish(_ ticket: RepositoryRefreshTicket) -> Bool {
        guard isCurrent(ticket) else { return false }
        hasInFlightRefresh = false
        return true
    }
}

/// The VCS dirty-scope projection of a worktree event batch. `files` are
/// exact paths, `directories` are recursively dirty, and
/// `nonRecursiveDirectories` preserve the parent-directory invalidation that
/// IntelliJ records for a rename. `everything` is set when a path cannot be
/// safely scoped (for example an unpaired rename or an ignore-file change).
struct RepositoryDirtyScope: Equatable, Sendable {
    let files: [String]
    let directories: [String]
    let nonRecursiveDirectories: [String]
    let everything: Bool

    var isEmpty: Bool {
        files.isEmpty
            && directories.isEmpty
            && nonRecursiveDirectories.isEmpty
            && !everything
    }
}

extension RepositoryDirtyScope {
    private static let rootDirtyFolderSizeThreshold = 30
    private static let rootDirtyScopeSizeThreshold = 50_000

    func merged(
        with other: RepositoryDirtyScope,
        workdir: String? = nil
    ) -> RepositoryDirtyScope {
        let merged = RepositoryDirtyScope(
            files: Array(Set(files).union(other.files)).sorted(),
            directories: Array(Set(directories).union(other.directories)).sorted(),
            nonRecursiveDirectories: Array(
                Set(nonRecursiveDirectories).union(other.nonRecursiveDirectories)
            ).sorted(),
            everything: everything || other.everything
        )
        return workdir.map { merged.compacted(workdir: $0) } ?? merged
    }

    /// Applies the useful part of IntelliJ's RootDirtySet.compact() to the
    /// path-based representation used by Arbor. A dirty ancestor supersedes
    /// all descendants; once one folder accumulates enough dirty descendants,
    /// the scope is promoted to that folder, matching RootDirtySet's bounded
    /// path-count behavior.
    func compacted(workdir: String) -> RepositoryDirtyScope {
        guard !everything else { return self }

        let root = repositoryEventKey(workdir)
        let rawFiles = Set(files.map(repositoryEventKey))
        let rawDirectories = Set(directories.map(repositoryEventKey))
        let rawNonRecursiveDirectories = Set(nonRecursiveDirectories.map(repositoryEventKey))
        let rawPaths = rawFiles.union(rawDirectories).union(rawNonRecursiveDirectories)

        guard rawPaths.allSatisfy({ isRepositoryPath($0, isSameOrDescendantOf: root) }),
              !rawPaths.contains(root) else {
            return RepositoryDirtyScope(
                files: [],
                directories: [],
                nonRecursiveDirectories: [],
                everything: true
            )
        }
        var retainedPaths = Self.removeDescendants(rawPaths)
        var promotedDirectories = Set<String>()

        while true {
            var descendantCounts: [String: Int] = [:]
            for path in retainedPaths {
                var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                while isRepositoryPath(parent, isSameOrDescendantOf: root), parent != root {
                    descendantCounts[parent, default: 0] += 1
                    parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
                }
            }

            guard let candidate = descendantCounts
                .filter({ $0.value >= Self.rootDirtyFolderSizeThreshold })
                .map(\.key)
                .sorted(by: { lhs, rhs in
                    let lhsDepth = lhs.split(separator: "/").count
                    let rhsDepth = rhs.split(separator: "/").count
                    if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
                    return lhs < rhs
                })
                .first else {
                break
            }

            if candidate == root {
                return RepositoryDirtyScope(
                    files: [],
                    directories: [],
                    nonRecursiveDirectories: [],
                    everything: true
                )
            }
            promotedDirectories.insert(candidate)
            retainedPaths = retainedPaths.filter {
                !isRepositoryPath($0, isSameOrDescendantOf: candidate)
            }
            retainedPaths.insert(candidate)
        }

        guard retainedPaths.count <= Self.rootDirtyScopeSizeThreshold else {
            return RepositoryDirtyScope(
                files: [],
                directories: [],
                nonRecursiveDirectories: [],
                everything: true
            )
        }

        let recursiveDirectories = Self.removeDescendants(
            rawDirectories.union(promotedDirectories)
        )
        let nonRecursive = Self.removeDescendants(rawNonRecursiveDirectories)
            .filter { path in
                !recursiveDirectories.contains {
                    isRepositoryPath(path, isSameOrDescendantOf: $0)
                }
            }
        let exactFiles = Self.removeDescendants(rawFiles)
            .filter { path in
                !recursiveDirectories.contains {
                    isRepositoryPath(path, isSameOrDescendantOf: $0)
                }
                && !nonRecursive.contains {
                    isRepositoryPath(path, isSameOrDescendantOf: $0)
                }
            }

        return RepositoryDirtyScope(
            files: exactFiles.sorted(),
            directories: recursiveDirectories.sorted(),
            nonRecursiveDirectories: nonRecursive.sorted(),
            everything: false
        )
    }

    /// Returns true only when a recursive directory scope covers the path.
    /// This distinction is needed for GitVcsDirtyScope's nested-root
    /// propagation: an exact file or rename-parent marker must not invalidate
    /// an unrelated child repository.
    func recursivelyContains(path: String, workdir: String) -> Bool {
        let root = repositoryEventKey(workdir)
        let normalized = repositoryEventKey(path)
        guard isRepositoryPath(normalized, isSameOrDescendantOf: root) else {
            return false
        }
        return everything || directories.contains {
            isRepositoryPath(normalized, isSameOrDescendantOf: $0)
        }
    }

    private static func removeDescendants(_ paths: Set<String>) -> Set<String> {
        var retained = Set<String>()
        for path in paths.sorted() {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            var covered = false
            while !parent.isEmpty {
                if retained.contains(parent) {
                    covered = true
                    break
                }
                let next = URL(fileURLWithPath: parent).deletingLastPathComponent().path
                if next == parent { break }
                parent = next
            }
            if !covered {
                retained.insert(path)
            }
        }
        return retained
    }

    /// Mirrors RootDirtySet.belongsTo: an exact file or a descendant of a
    /// dirty directory belongs to this scope, while a clean root itself does
    /// not. Paths are normalized before comparison so packed scopes remain
    /// stable across relative/absolute VFS spellings.
    func contains(path: String, workdir: String) -> Bool {
        let root = URL(fileURLWithPath: workdir).standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized == root || normalized.hasPrefix(root + "/") else {
            return false
        }
        if everything { return true }
        if files.contains(normalized) { return true }

        func containsDescendant(_ directory: String) -> Bool {
            normalized == directory || normalized.hasPrefix(directory + "/")
        }
        return directories.contains(where: containsDescendant)
            || nonRecursiveDirectories.contains(normalized)
    }
}

struct RepositoryDirtyScopeRecord: Equatable, Sendable {
    let repositoryPath: String
    let scope: RepositoryDirtyScope
    /// The metadata needed to replay the visible refresh after the scope is
    /// packed. Keeping it with the scope mirrors IntelliJ's invalidated
    /// batch: later events may wait in `pending` without losing whether the
    /// current batch changed Git metadata or which rename endpoints it saw.
    let changeScope: RepositoryChangeScope
    let dirtyPaths: [RepositoryDirtyPath]

    init(
        repositoryPath: String,
        scope: RepositoryDirtyScope,
        changeScope: RepositoryChangeScope = .worktree,
        dirtyPaths: [RepositoryDirtyPath] = []
    ) {
        self.repositoryPath = repositoryPath
        self.scope = scope
        self.changeScope = changeScope
        self.dirtyPaths = dirtyPaths
    }

    var event: RepositoryChangeEvent {
        RepositoryChangeEvent(
            repositoryPath: repositoryPath,
            scopes: changeScope,
            dirtyPaths: dirtyPaths
        )
    }
}

struct RepositoryDirtyScopeTicket: Equatable, Sendable {
    let repositoryPath: String
    let generation: UInt64
}

/// Exact file-level dirty state preserved alongside the compacted scope. This
/// is the Swift equivalent of IntelliJ's untracked/dirty VFS listeners: the
/// scope may be promoted to a directory for efficient status refresh, but the
/// original file event and both rename endpoints still have a lifecycle of
/// pending -> in-progress -> processed.
struct RepositoryDirtyFileRecord: Equatable, Sendable {
    let repositoryPath: String
    let path: String
    let oldPath: String?
    let isDirectory: Bool
    let kind: RepositoryDirtyChangeKind

    var endpoints: [String] {
        [path, oldPath].compactMap { $0 }
    }
}

struct RepositoryDirtyFileTicket: Equatable, Sendable {
    let repositoryPath: String
    let generation: UInt64
    let records: [RepositoryDirtyFileRecord]
}

/// Tracks exact VFS file events independently from RootDirtySet-style scope
/// compaction. Keeping this ledger prevents a directory promotion from
/// erasing the old path of a rename or making a later refresh acknowledge a
/// newer file event too early.
struct RepositoryDirtyFileManager: Equatable, Sendable {
    private var pending: [String: [String: RepositoryDirtyFileRecord]] = [:]
    private var inProgress: [String: [UInt64: [String: RepositoryDirtyFileRecord]]] = [:]
    private var nextGeneration: UInt64 = 0

    var hasDirtyFiles: Bool { pending.values.contains { !$0.isEmpty } }
    var hasInProgressFiles: Bool {
        inProgress.values.contains { !$0.isEmpty }
    }

    mutating func mark(repositoryPath: String, dirtyPaths: [RepositoryDirtyPath]) {
        let root = repositoryEventKey(repositoryPath)
        guard !dirtyPaths.isEmpty else { return }
        var records = pending[root] ?? [:]
        for dirtyPath in dirtyPaths {
            let path = repositoryEventKey(dirtyPath.path)
            let incoming = RepositoryDirtyFileRecord(
                repositoryPath: root,
                path: path,
                oldPath: dirtyPath.oldPath.map(repositoryEventKey),
                isDirectory: dirtyPath.isDirectory,
                kind: dirtyPath.kind
            )
            if let previous = records[path] {
                records[path] = merge(previous, incoming)
            } else {
                records[path] = incoming
            }
        }
        pending[root] = records
    }

    mutating func beginProcessing(repositoryPath: String) -> RepositoryDirtyFileTicket? {
        let root = repositoryEventKey(repositoryPath)
        guard let records = pending.removeValue(forKey: root), !records.isEmpty else {
            return nil
        }
        nextGeneration &+= 1
        inProgress[root, default: [:]][nextGeneration] = records
        return RepositoryDirtyFileTicket(
            repositoryPath: root,
            generation: nextGeneration,
            records: records.values.sorted { lhs, rhs in
                if lhs.path != rhs.path { return lhs.path < rhs.path }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
        )
    }

    mutating func changesProcessed(_ ticket: RepositoryDirtyFileTicket) {
        let root = repositoryEventKey(ticket.repositoryPath)
        guard var records = inProgress[root] else { return }
        records.removeValue(forKey: ticket.generation)
        if records.isEmpty {
            inProgress.removeValue(forKey: root)
        } else {
            inProgress[root] = records
        }
    }

    mutating func changesProcessed(repositoryPath: String) {
        inProgress.removeValue(forKey: repositoryEventKey(repositoryPath))
    }

    /// Returns all pending and in-progress exact events without changing
    /// their lifecycle state, useful for diagnostics and regression tests.
    func pack() -> [RepositoryDirtyFileRecord] {
        var records: [String: RepositoryDirtyFileRecord] = [:]
        let all = pending.values.flatMap { $0.values }
            + inProgress.values.flatMap { $0.values.flatMap { $0.values } }
        for incoming in all {
            if let previous = records[incoming.path] {
                records[incoming.path] = merge(previous, incoming)
            } else {
                records[incoming.path] = incoming
            }
        }
        return records.values.sorted {
            if $0.repositoryPath != $1.repositoryPath {
                return $0.repositoryPath < $1.repositoryPath
            }
            return $0.path < $1.path
        }
    }

    mutating func removeAll() {
        pending.removeAll()
        inProgress.removeAll()
    }

    private func merge(
        _ previous: RepositoryDirtyFileRecord,
        _ incoming: RepositoryDirtyFileRecord
    ) -> RepositoryDirtyFileRecord {
        let oldPath: String?
        switch (previous.oldPath, incoming.oldPath) {
        case let (lhs?, rhs?) where repositoryEventKey(lhs) != repositoryEventKey(rhs):
            oldPath = nil
        case let (lhs?, _):
            oldPath = lhs
        case let (_, rhs?):
            oldPath = rhs
        default:
            oldPath = nil
        }
        return RepositoryDirtyFileRecord(
            repositoryPath: previous.repositoryPath,
            path: previous.path,
            oldPath: oldPath,
            isDirectory: previous.isDirectory || incoming.isDirectory,
            kind: RepositoryDirtyChangeKind.merging(previous.kind, incoming.kind)
        )
    }
}

/// Root-scoped analogue of IntelliJ's VcsDirtyScopeManager + GitVcsDirtyScope.
/// New events remain pending while a packed scope is being consumed; callers
/// must explicitly finish the in-progress root before retrieving the next
/// packed scope. This prevents a refresh from acknowledging a later event
/// batch as if it belonged to the previous one.
struct RepositoryDirtyScopeManager: Equatable, Sendable {
    private var pending: [String: RepositoryDirtyScopeRecord] = [:]
    private var inProgress: [String: [UInt64: RepositoryDirtyScopeRecord]] = [:]
    private var knownRoots: Set<String> = []
    private var nextGeneration: UInt64 = 0

    var hasDirtyScopes: Bool { !pending.isEmpty }
    var hasInProgressScopes: Bool {
        inProgress.values.contains { !$0.isEmpty }
    }

    mutating func register(repositoryPaths: [String]) {
        knownRoots.formUnion(repositoryPaths.map(repositoryEventKey))
    }

    @discardableResult
    mutating func mark(
        repositoryPath: String,
        scope: RepositoryDirtyScope,
        changeScope: RepositoryChangeScope = .worktree,
        dirtyPaths: [RepositoryDirtyPath] = []
    ) -> [String] {
        let normalizedPath = repositoryEventKey(repositoryPath)
        knownRoots.insert(normalizedPath)
        let compactedScope = scope.compacted(workdir: normalizedPath)
        let incoming = RepositoryDirtyScopeRecord(
            repositoryPath: normalizedPath,
            scope: compactedScope,
            changeScope: changeScope,
            dirtyPaths: dirtyPaths
        )
        if let previous = pending[normalizedPath] {
            pending[normalizedPath] = mergedRepositoryDirtyScopeRecord(
                previous,
                incoming,
                workdir: normalizedPath
            )
        } else {
            pending[normalizedPath] = incoming
        }

        var affectedRoots = [normalizedPath]
        let nestedRoots = knownRoots
            .filter {
                $0 != normalizedPath
                    && isRepositoryPath($0, isSameOrDescendantOf: normalizedPath)
                    && compactedScope.recursivelyContains(
                        path: $0,
                        workdir: normalizedPath
                    )
            }
            .sorted()
        for nestedRoot in nestedRoots {
            affectedRoots.append(contentsOf: mark(
                repositoryPath: nestedRoot,
                scope: RepositoryDirtyScope(
                    files: [],
                    directories: [],
                    nonRecursiveDirectories: [],
                    everything: true
                ),
                changeScope: changeScope,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: nestedRoot,
                        isDirectory: true,
                        kind: .modified
                    )
                ]
            ))
        }
        return Array(Set(affectedRoots)).sorted()
    }

    @discardableResult
    mutating func markEverything(
        repositoryPath: String,
        changeScope: RepositoryChangeScope = .worktree,
        dirtyPaths: [RepositoryDirtyPath] = []
    ) -> [String] {
        mark(
            repositoryPath: repositoryPath,
            scope: RepositoryDirtyScope(
                files: [],
                directories: [],
                nonRecursiveDirectories: [],
                everything: true
            ),
            changeScope: changeScope,
            dirtyPaths: dirtyPaths
        )
    }

    /// Packs pending scopes for processing and moves them to the in-progress
    /// set. A second retrieval is rejected until the first packed scope is
    /// acknowledged, matching VcsDirtyScopeManager's lifecycle boundary.
    mutating func retrieveScopes() -> [RepositoryDirtyScopeRecord] {
        guard !hasInProgressScopes, !pending.isEmpty else { return [] }
        let result = pending.values.sorted {
            $0.repositoryPath < $1.repositoryPath
        }
        for record in result {
            nextGeneration &+= 1
            inProgress[repositoryEventKey(record.repositoryPath), default: [:]][nextGeneration] = record
        }
        pending.removeAll()
        return result
    }

    mutating func beginProcessing(repositoryPath: String) -> RepositoryDirtyScopeTicket? {
        let normalizedPath = repositoryEventKey(repositoryPath)
        guard !hasInProgressScopes,
              let record = pending.removeValue(forKey: normalizedPath) else {
            return nil
        }
        nextGeneration &+= 1
        inProgress[normalizedPath, default: [:]][nextGeneration] = record
        return RepositoryDirtyScopeTicket(
            repositoryPath: normalizedPath,
            generation: nextGeneration
        )
    }

    mutating func changesProcessed(_ ticket: RepositoryDirtyScopeTicket) {
        let key = repositoryEventKey(ticket.repositoryPath)
        guard var records = inProgress[key] else { return }
        records.removeValue(forKey: ticket.generation)
        if records.isEmpty {
            inProgress.removeValue(forKey: key)
        } else {
            inProgress[key] = records
        }
    }

    mutating func changesProcessed(repositoryPath: String) {
        inProgress.removeValue(forKey: repositoryEventKey(repositoryPath))
    }

    mutating func changesProcessed() {
        inProgress.removeAll()
    }

    /// Returns a stable snapshot without changing pending/in-progress state.
    /// This is the Swift equivalent of GitVcsDirtyScope.pack().
    func pack() -> [RepositoryDirtyScopeRecord] {
        var records: [String: RepositoryDirtyScopeRecord] = [:]
        let inProgressRecords = inProgress.values.flatMap { $0.values }
        for record in Array(pending.values) + Array(inProgressRecords) {
            let key = repositoryEventKey(record.repositoryPath)
            if let previous = records[key] {
                records[key] = mergedRepositoryDirtyScopeRecord(
                    previous,
                    record,
                    workdir: previous.repositoryPath
                )
            } else {
                records[key] = record
            }
        }
        return records.values.sorted {
            $0.repositoryPath < $1.repositoryPath
        }
    }

    func belongsTo(repositoryPath: String, path: String) -> Bool {
        let key = repositoryEventKey(repositoryPath)
        var record = pending[key]
        let inProgressRecords = inProgress[key].map { Array($0.values) } ?? []
        for inProgressRecord in inProgressRecords {
            if let existing = record {
                record = RepositoryDirtyScopeRecord(
                    repositoryPath: existing.repositoryPath,
                    scope: existing.scope.merged(
                        with: inProgressRecord.scope,
                        workdir: existing.repositoryPath
                    )
                )
            } else {
                record = inProgressRecord
            }
        }
        guard let record else { return false }
        return record.scope.contains(path: path, workdir: record.repositoryPath)
    }

    mutating func removeAll() {
        pending.removeAll()
        inProgress.removeAll()
        knownRoots.removeAll()
    }
}

private func mergedRepositoryDirtyScopeRecord(
    _ lhs: RepositoryDirtyScopeRecord,
    _ rhs: RepositoryDirtyScopeRecord,
    workdir: String
) -> RepositoryDirtyScopeRecord {
    let mergedEvent = lhs.event.merged(with: rhs.event)
    return RepositoryDirtyScopeRecord(
        repositoryPath: repositoryEventKey(workdir),
        scope: lhs.scope.merged(with: rhs.scope, workdir: workdir),
        changeScope: mergedEvent?.scopes ?? lhs.changeScope.union(rhs.changeScope),
        dirtyPaths: mergedEvent?.dirtyPaths ?? (lhs.dirtyPaths + rhs.dirtyPaths)
    )
}

func repositoryDirtyScope(
    workdir: String,
    gitDir: String,
    dirtyPaths: [RepositoryDirtyPath]
) -> RepositoryDirtyScope {
    let workdirPath = URL(fileURLWithPath: workdir).standardizedFileURL.path
    let gitDirPath = URL(fileURLWithPath: gitDir).standardizedFileURL.path
    let worktreePrefix = workdirPath.hasSuffix("/") ? workdirPath : "\(workdirPath)/"
    let gitDirPrefix = gitDirPath.hasSuffix("/") ? gitDirPath : "\(gitDirPath)/"
    var files = Set<String>()
    var directories = Set<String>()
    var nonRecursiveDirectories = Set<String>()
    var everything = false

    func addRenameParent(_ path: String) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != workdirPath else { return }
        nonRecursiveDirectories.insert(parent)
    }

    func addEndpoint(_ path: String, isDirectory: Bool) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == gitDirPath || normalized.hasPrefix(gitDirPrefix) {
            return true
        }
        guard normalized != workdirPath, normalized.hasPrefix(worktreePrefix) else {
            return false
        }
        let relative = String(normalized.dropFirst(worktreePrefix.count))
        guard !relative.isEmpty else { return false }
        if relative == ".git" || relative.hasPrefix(".git/") {
            return true
        }
        if relative == ".gitignore" || relative.hasSuffix("/.gitignore") {
            return false
        }
        if isDirectory {
            directories.insert(normalized)
        } else {
            files.insert(normalized)
        }
        return true
    }

    for dirtyPath in dirtyPaths {
        if dirtyPath.kind == .renamed {
            guard let oldPath = dirtyPath.oldPath,
                  addEndpoint(oldPath, isDirectory: dirtyPath.isDirectory),
                  addEndpoint(dirtyPath.path, isDirectory: dirtyPath.isDirectory) else {
                everything = true
                continue
            }
            addRenameParent(oldPath)
            continue
        }
        if !addEndpoint(dirtyPath.path, isDirectory: dirtyPath.isDirectory) {
            everything = true
        }
    }

    return RepositoryDirtyScope(
        files: files.sorted(),
        directories: directories.sorted(),
        nonRecursiveDirectories: nonRecursiveDirectories.sorted(),
        everything: everything
    )
}

/// IntelliJ's VcsVFSListener keeps independent confirmation policies for
/// files added to and removed from version control. `ask` is the safe default;
/// `perform` mirrors DO_ACTION_SILENTLY and `ignore` mirrors
/// DO_NOTHING_SILENTLY.
enum GitVFSListenerAction: String, CaseIterable, Identifiable, Sendable {
    case ask
    case perform
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask for confirmation"
        case .perform: "Perform silently"
        case .ignore: "Do nothing"
        }
    }
}

enum GitVFSListenerSettings {
    static let addActionKey = "arbor.git.vfsListener.addAction.v1"
    static let removeActionKey = "arbor.git.vfsListener.removeAction.v1"

    static func addAction(defaults: UserDefaults = .standard) -> GitVFSListenerAction {
        action(forKey: addActionKey, defaults: defaults)
    }

    static func removeAction(defaults: UserDefaults = .standard) -> GitVFSListenerAction {
        action(forKey: removeActionKey, defaults: defaults)
    }

    static func setAddAction(
        _ action: GitVFSListenerAction,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(action.rawValue, forKey: addActionKey)
    }

    static func setRemoveAction(
        _ action: GitVFSListenerAction,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(action.rawValue, forKey: removeActionKey)
    }

    private static func action(
        forKey key: String,
        defaults: UserDefaults
    ) -> GitVFSListenerAction {
        guard let rawValue = defaults.string(forKey: key),
              let action = GitVFSListenerAction(rawValue: rawValue) else {
            return .ask
        }
        return action
    }
}

struct RepositoryExternalVCSActionPaths: Equatable, Sendable {
    let add: [String]
    /// Newly created worktree files use IntelliJ staging-area's empty-blob
    /// index path. Rename destinations remain in `add` because IntelliJ's
    /// move/rename action stages their complete content.
    let stageAdd: [String]
    let remove: [String]
    let forceMove: [RepositoryExternalVCSMove]
    /// Rename candidates whose old endpoint could not be proven from the
    /// filesystem identity. They require an explicit user choice.
    let reviewMoves: [RepositoryExternalVCSMove]

    var isEmpty: Bool {
        add.isEmpty
            && stageAdd.isEmpty
            && remove.isEmpty
            && forceMove.isEmpty
            && reviewMoves.isEmpty
    }

    init(
        add: [String],
        remove: [String],
        stageAdd: [String] = [],
        forceMove: [RepositoryExternalVCSMove] = [],
        reviewMoves: [RepositoryExternalVCSMove] = []
    ) {
        self.add = add
        self.stageAdd = stageAdd
        self.remove = remove
        self.forceMove = forceMove
        self.reviewMoves = reviewMoves
    }
}

struct RepositoryExternalVCSMove: Codable, Equatable, Hashable, Sendable {
    let oldPath: String
    let newPath: String
}

/// The exact paths a user approved for an external VFS Git action. Keeping
/// this separate from the raw watcher event makes Retry replay only confirmed
/// work, never an unreviewed rename candidate.
struct RepositoryExternalVCSAction: Codable, Equatable, Sendable {
    let addPaths: [String]
    let stageAddPaths: [String]
    let removePaths: [String]
    let forceMoves: [RepositoryExternalVCSMove]

    var isEmpty: Bool {
        addPaths.isEmpty
            && stageAddPaths.isEmpty
            && removePaths.isEmpty
            && forceMoves.isEmpty
    }
}

func repositoryExternalVCSActionPathIsSafe(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    return !path.hasPrefix("/")
        && !components.isEmpty
        && !components.contains(".")
        && !components.contains("..")
        && !path.contains("\\")
        && !components.contains(".git")
}

func repositoryExternalVCSActionIsSafe(
    _ action: RepositoryExternalVCSAction
) -> Bool {
    let paths = action.addPaths + action.stageAddPaths + action.removePaths
    return paths.allSatisfy(repositoryExternalVCSActionPathIsSafe)
        && action.forceMoves.allSatisfy {
            repositoryExternalVCSActionPathIsSafe($0.oldPath)
                && repositoryExternalVCSActionPathIsSafe($0.newPath)
        }
}

/// Keep an explicitly selected rename set one-to-one. Ambiguous directory
/// matching can produce several old endpoints for one destination (or the
/// same old endpoint for several destinations); applying either conflict as a
/// Git add/remove pair would not be a rename and could remove unrelated index
/// entries.
func repositoryNonConflictingExternalVCSMoves(
    _ moves: [RepositoryExternalVCSMove]
) -> [RepositoryExternalVCSMove] {
    var oldPaths = Set<String>()
    var newPaths = Set<String>()
    return moves.filter { move in
        guard oldPaths.insert(move.oldPath).inserted,
              newPaths.insert(move.newPath).inserted else {
            return false
        }
        return true
    }
}

/// Applies the user's per-path selection while preserving the action order
/// and removing duplicate endpoints from a coalesced VFS batch.
func repositorySelectedExternalVCSPaths(
    paths: [String],
    selected: Set<String>
) -> [String] {
    var seen = Set<String>()
    return paths.filter { selected.contains($0) && seen.insert($0).inserted }
}

/// Build per-file rename candidates for a directory event whose old endpoint
/// is unavailable or has multiple possible filesystem identities. Matching is
/// limited to the unchanged path suffix; every candidate remains a proposal
/// until the user explicitly selects it.
func repositoryAmbiguousDirectoryRenameCandidates(
    directoryPath: String,
    newEntries: [FileEntry],
    status: [FileEntry]
) -> [RepositoryExternalVCSMove] {
    let prefix = directoryPath.hasSuffix("/")
        ? directoryPath
        : "\(directoryPath)/"
    let newPaths = newEntries
        .filter { $0.unstaged == .untracked }
        .map(\.path)
        .filter { $0.hasPrefix(prefix) }
    let deletedPaths = status
        .filter { $0.unstaged == .deleted }
        .map(\.path)

    var candidates = Set<RepositoryExternalVCSMove>()
    for newPath in newPaths {
        let suffix = String(newPath.dropFirst(prefix.count))
        guard !suffix.isEmpty else { continue }
        for oldPath in deletedPaths where
            oldPath == suffix || oldPath.hasSuffix("/\(suffix)") {
            candidates.insert(
                RepositoryExternalVCSMove(oldPath: oldPath, newPath: newPath)
            )
        }
    }
    return candidates.sorted {
        if $0.newPath != $1.newPath { return $0.newPath < $1.newPath }
        return $0.oldPath < $1.oldPath
    }
}

/// Build candidates for an unpaired file rename when the watcher omitted the
/// old endpoint and the status scan contains more than one deleted path. A
/// basename match keeps the review bounded to plausible old endpoints while
/// still requiring an explicit choice before removing any old path.
func repositoryAmbiguousFileRenameCandidates(
    newPath: String,
    deletedPaths: [String]
) -> [RepositoryExternalVCSMove] {
    let basename = URL(fileURLWithPath: newPath).lastPathComponent
    guard !basename.isEmpty else { return [] }

    return deletedPaths
        .filter { oldPath in
            oldPath != newPath
                && URL(fileURLWithPath: oldPath).lastPathComponent == basename
        }
        .map { RepositoryExternalVCSMove(oldPath: $0, newPath: newPath) }
        .sorted { $0.oldPath < $1.oldPath }
}

/// Recover only unpaired file renames whose new worktree content and old
/// index blob have the same Git object id. The mapping must be one-to-one on
/// both sides; equal-content duplicates stay ambiguous and continue through
/// the basename review/conservative path. Git's --path hashing applies the
/// same clean filter used for the index, and the command is read-only.
func repositoryUniqueContentRenameMatches(
    repo: Repository,
    event: RepositoryChangeEvent,
    workdir: String,
    status: [FileEntry]
) -> [RepositoryExternalVCSMove] {
    let deletedPaths = Set(
        status
            .filter { $0.unstaged == .deleted }
            .map(\.path)
    )
    guard !deletedPaths.isEmpty else { return [] }

    let newPaths = Set(
        event.dirtyPaths.compactMap { dirtyPath -> String? in
            guard dirtyPath.kind == .renamed,
                  dirtyPath.oldPath == nil,
                  !dirtyPath.isDirectory,
                  let relative = repositoryRelativeWorktreeEventPath(
                      workdir: workdir,
                      path: dirtyPath.path
                  ),
                  status.contains(where: {
                      $0.path == relative && $0.unstaged == .untracked
                  }) else {
                return nil
            }
            return relative
        }
    )
    guard !newPaths.isEmpty else { return [] }

    var newPathsByBlob: [String: [String]] = [:]
    for path in newPaths.sorted() {
        guard repositoryExternalVCSActionPathIsSafe(path),
              let blob = try? repo.worktreeBlobId(path: path),
              !blob.isEmpty else { continue }
        newPathsByBlob[blob, default: []].append(path)
    }

    var oldPathsByBlob: [String: [String]] = [:]
    for path in deletedPaths.sorted() {
        guard repositoryExternalVCSActionPathIsSafe(path),
              let blob = try? repo.indexBlobId(path: path),
              !blob.isEmpty else { continue }
        oldPathsByBlob[blob, default: []].append(path)
    }

    return newPathsByBlob.keys.compactMap { blob in
        guard let newPaths = newPathsByBlob[blob],
              let oldPaths = oldPathsByBlob[blob],
              newPaths.count == 1,
              oldPaths.count == 1 else {
            return nil
        }
        return RepositoryExternalVCSMove(
            oldPath: oldPaths[0],
            newPath: newPaths[0]
        )
    }.sorted {
        if $0.newPath != $1.newPath { return $0.newPath < $1.newPath }
        return $0.oldPath < $1.oldPath
    }
}

/// Estimate Git's rename similarity for text files using a line multiset.
/// Git's native detector works on unchanged content chunks; line-level Dice
/// overlap gives the same useful safety boundary here without invoking a
/// second mutating or user-configured diff driver. The caller still requires
/// a unique best candidate and a margin over the next candidate.
func repositoryRenameSimilarityScore(_ oldText: String, _ newText: String) -> Double {
    func lines(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let value = String(line)
                return value.hasSuffix("\r") ? String(value.dropLast()) : value
            }
    }

    let oldLines = lines(oldText)
    let newLines = lines(newText)
    guard !oldLines.isEmpty || !newLines.isEmpty else { return 1 }
    guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }

    var oldCounts: [String: Int] = [:]
    for line in oldLines {
        oldCounts[line, default: 0] += 1
    }
    var common = 0
    for line in newLines {
        guard let count = oldCounts[line], count > 0 else { continue }
        common += 1
        oldCounts[line] = count - 1
    }
    return Double(common * 2) / Double(oldLines.count + newLines.count)
}

/// Recover modified, unpaired file renames when Git's status scan cannot
/// provide an old endpoint. Exact blob identity remains the stronger signal;
/// this fallback only accepts text files with a unique high-similarity match,
/// a meaningful margin over the next candidate, and one-to-one endpoints.
func repositoryModifiedContentRenameMatches(
    repo: Repository,
    event: RepositoryChangeEvent,
    workdir: String,
    status: [FileEntry],
    reservedMoves: [RepositoryExternalVCSMove] = []
) -> [RepositoryExternalVCSMove] {
    let reservedOldPaths = Set(reservedMoves.map(\.oldPath))
    let reservedNewPaths = Set(reservedMoves.map(\.newPath))
    let deletedPaths = status
        .filter { $0.unstaged == .deleted && !reservedOldPaths.contains($0.path) }
        .map(\.path)
    guard !deletedPaths.isEmpty else { return [] }

    let newPaths = Set(
        event.dirtyPaths.compactMap { dirtyPath -> String? in
            guard dirtyPath.kind == .renamed,
                  dirtyPath.oldPath == nil,
                  !dirtyPath.isDirectory,
                  let relative = repositoryRelativeWorktreeEventPath(
                      workdir: workdir,
                      path: dirtyPath.path
                  ),
                  !reservedNewPaths.contains(relative),
                  status.contains(where: {
                      $0.path == relative && $0.unstaged == .untracked
                  }) else {
                return nil
            }
            return relative
        }
    )
    guard !newPaths.isEmpty else { return [] }

    struct ScoredMove {
        let move: RepositoryExternalVCSMove
        let score: Double
    }

    var bestByNewPath: [String: ScoredMove] = [:]
    for newPath in newPaths.sorted() {
        guard repositoryExternalVCSActionPathIsSafe(newPath),
              let newContent = try? repo.readWorktreeFile(path: newPath),
              !newContent.binary,
              !newContent.truncated,
              !newContent.text.contains("\u{FFFD}") else { continue }

        let scored = deletedPaths.compactMap { oldPath -> ScoredMove? in
            guard repositoryExternalVCSActionPathIsSafe(oldPath),
                  let oldContent = try? repo.readIndexFile(path: oldPath),
                  !oldContent.binary,
                  !oldContent.truncated,
                  !oldContent.text.contains("\u{FFFD}") else { return nil }
            let score = repositoryRenameSimilarityScore(
                oldContent.text,
                newContent.text
            )
            return ScoredMove(
                move: RepositoryExternalVCSMove(oldPath: oldPath, newPath: newPath),
                score: score
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.move.oldPath < $1.move.oldPath
        }
        guard let best = scored.first,
              best.score >= 0.60,
              scored.dropFirst().first.map({ best.score - $0.score >= 0.10 }) ?? true else {
            continue
        }
        bestByNewPath[newPath] = best
    }

    // If two destinations independently select one deleted source, retain
    // neither proposal. Choosing one would silently turn the other into a
    // regular add and make the old endpoint ownership non-deterministic.
    let groupedByOldPath = Dictionary(grouping: bestByNewPath.values, by: { $0.move.oldPath })
    return bestByNewPath.values
        .filter { groupedByOldPath[$0.move.oldPath]?.count == 1 }
        .map(\.move)
        .sorted {
            if $0.newPath != $1.newPath { return $0.newPath < $1.newPath }
            return $0.oldPath < $1.oldPath
        }
}

/// Returns the relative Git path for a worktree event. Events outside this
/// worktree, the worktree root itself, and administrative `.git` paths are not
/// eligible for VcsVFSListener actions.
func repositoryRelativeWorktreeEventPath(workdir: String, path: String) -> String? {
    let workdirPath = URL(fileURLWithPath: workdir).standardizedFileURL.path
    let pathValue = URL(fileURLWithPath: path).standardizedFileURL.path
    let prefix = workdirPath.hasSuffix("/") ? workdirPath : "\(workdirPath)/"
    guard pathValue.hasPrefix(prefix) else { return nil }
    let relative = String(pathValue.dropFirst(prefix.count))
    guard !relative.isEmpty,
          relative != ".git",
          !relative.hasPrefix(".git/") else { return nil }
    return relative
}

struct RepositoryFileSnapshot: Hashable, Sendable {
    let identity: String
    let isDirectory: Bool
}

/// Captures stable filesystem identities without reading file contents. The
/// device/inode pair survives an ordinary rename, while independently created
/// files do not share it. This lets the watcher recover the old endpoint that
/// FSEvents omits, without guessing from names or timestamps.
func repositoryFileSnapshots(
    rootPath: String,
    excludedRootPaths: [String] = []
) -> [String: RepositoryFileSnapshot] {
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL
    let excluded = excludedRootPaths.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    }
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else { return [:] }

    var snapshots: [String: RepositoryFileSnapshot] = [:]
    for case let url as URL in enumerator {
        let path = url.standardizedFileURL.path
        if url.lastPathComponent == ".git" {
            enumerator.skipDescendants()
            continue
        }
        if excluded.contains(where: { excludedPath in
            path == excludedPath || path.hasPrefix(excludedPath + "/")
        }) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
            }
            continue
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            continue
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        snapshots[path] = RepositoryFileSnapshot(
            identity: "\(device):\(inode)",
            isDirectory: isDirectory
        )
    }
    return snapshots
}

/// Pairs only unique old/new filesystem identities. Directory events may
/// authorize descendants when the new endpoint is under the moved directory;
/// if either side is ambiguous or absent, the original event is preserved and
/// callers retain their full-refresh fallback instead of inventing a move.
func repositoryPairRenameEvents(
    dirtyPaths: [RepositoryDirtyPath],
    previous: [String: RepositoryFileSnapshot],
    current: [String: RepositoryFileSnapshot]
) -> [RepositoryDirtyPath] {
    var previousByIdentity: [String: [String]] = [:]
    var currentByIdentity: [String: [String]] = [:]
    for (path, snapshot) in previous {
        previousByIdentity[snapshot.identity, default: []].append(path)
    }
    for (path, snapshot) in current {
        currentByIdentity[snapshot.identity, default: []].append(path)
    }

    let changedPaths = Set(
        dirtyPaths.flatMap { [$0.path, $0.oldPath].compactMap { $0 } }
    )
    let renamedDirectories = dirtyPaths
        .filter { $0.kind == .renamed && $0.isDirectory }
        .map(\.path)
    var pairs: [RepositoryDirtyPath] = []
    var consumedPaths = Set<String>()

    for (identity, oldPaths) in previousByIdentity {
        guard oldPaths.count == 1,
              let newPaths = currentByIdentity[identity],
              newPaths.count == 1,
              let oldPath = oldPaths.first,
              let newPath = newPaths.first,
              oldPath != newPath,
              changedPaths.contains(oldPath)
                || changedPaths.contains(newPath)
                || renamedDirectories.contains(where: { directory in
                    newPath == directory || newPath.hasPrefix(directory + "/")
                }) else {
            continue
        }
        let isDirectory = current[newPath]?.isDirectory ?? false
        pairs.append(
            RepositoryDirtyPath(
                path: newPath,
                isDirectory: isDirectory,
                kind: .renamed,
                oldPath: oldPath
            )
        )
        consumedPaths.insert(oldPath)
        consumedPaths.insert(newPath)
    }

    let retained = dirtyPaths.filter { !consumedPaths.contains($0.path) }
    return (retained + pairs).sorted {
        if $0.path != $1.path { return $0.path < $1.path }
        if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
        return $0.kind.rawValue < $1.kind.rawValue
    }
}

/// Converts worktree events into the exact paths that IntelliJ's
/// GitVFSListener would offer to add/remove. Existing modified files are
/// deliberately excluded from the add set; ignored files are also excluded
/// because their status is not `Untracked`. Case-only moves are kept as a
/// separate force-move action.
func repositoryExternalVCSActionPaths(
    event: RepositoryChangeEvent,
    workdir: String,
    status: [FileEntry],
    contentRenameMatches: [RepositoryExternalVCSMove] = []
) -> RepositoryExternalVCSActionPaths {
    var addPaths = Set<String>()
    var stageAddPaths = Set<String>()
    var removePaths = Set<String>()
    var forceMoves = Set<RepositoryExternalVCSMove>()
    var reviewMoves = Set<RepositoryExternalVCSMove>()

    let trustedContentMoves = repositoryNonConflictingExternalVCSMoves(
        contentRenameMatches
    ).filter { move in
        let isEventRename = event.dirtyPaths.contains { dirtyPath in
            guard dirtyPath.kind == .renamed,
                  dirtyPath.oldPath == nil,
                  !dirtyPath.isDirectory,
                  let newPath = repositoryRelativeWorktreeEventPath(
                      workdir: workdir,
                      path: dirtyPath.path
                  ) else {
                return false
            }
            return newPath == move.newPath
        }
        return isEventRename
            && status.contains {
                $0.path == move.newPath && $0.unstaged == .untracked
            }
            && status.contains {
                $0.path == move.oldPath && $0.unstaged == .deleted
            }
    }
    let contentMatchedNewPaths = Set(trustedContentMoves.map(\.newPath))
    addPaths.formUnion(trustedContentMoves.map(\.newPath))
    removePaths.formUnion(trustedContentMoves.map(\.oldPath))

    for dirtyPath in event.dirtyPaths where
        dirtyPath.kind == .renamed && dirtyPath.oldPath == nil {
        guard let relative = repositoryRelativeWorktreeEventPath(
            workdir: workdir,
            path: dirtyPath.path
        ) else { continue }
        let newEntries = status.filter {
            $0.path == relative || $0.path.hasPrefix("\(relative)/")
        }
        // If Git's own full status scan gives one unambiguous rename record,
        // its oldPath is authoritative even though FSEvents omitted it.
        // A directory that remains unpaired can produce several records and
        // is intentionally kept on the conservative new-file path below.
        let detectedPairs = newEntries.compactMap { entry -> (String, String)? in
            guard entry.path == relative,
                  let oldPath = entry.oldPath,
                  entry.staged == .renamed || entry.unstaged == .renamed else {
                return nil
            }
            return (oldPath, entry.path)
        }
        if detectedPairs.count == 1,
           let (oldPath, newPath) = detectedPairs.first {
            if !dirtyPath.isDirectory,
               oldPath != newPath,
               oldPath.caseInsensitiveCompare(newPath) == .orderedSame {
                forceMoves.insert(
                    RepositoryExternalVCSMove(
                        oldPath: oldPath,
                        newPath: newPath
                    )
                )
            } else {
                addPaths.insert(newPath)
                removePaths.insert(oldPath)
            }
        } else {
            if contentMatchedNewPaths.contains(relative) {
                continue
            }
            let untrackedPaths = newEntries
                .filter { $0.unstaged == .untracked }
                .map(\.path)
            if dirtyPath.isDirectory {
                let candidates = repositoryAmbiguousDirectoryRenameCandidates(
                    directoryPath: relative,
                    newEntries: newEntries,
                    status: status
                )
                reviewMoves.formUnion(candidates)
                let reviewedNewPaths = Set(candidates.map(\.newPath))
                stageAddPaths.formUnion(
                    untrackedPaths.filter { !reviewedNewPaths.contains($0) }
                )
                continue
            }
            // FSEvents can report a rename without its old endpoint, and Git
            // can then expose the same move as one deleted tracked path plus
            // one untracked destination instead of a rename record. A
            // singleton deleted path is not identity evidence: it may be an
            // unrelated deletion in the same status batch. Only plausible
            // basename matches go through explicit move review; all other
            // destinations keep the conservative new-file fallback.
            let deletedPaths = status
                .filter { $0.unstaged == .deleted }
                .map(\.path)
            if untrackedPaths.count == 1,
               let newPath = untrackedPaths.first {
                let candidates = repositoryAmbiguousFileRenameCandidates(
                    newPath: newPath,
                    deletedPaths: deletedPaths
                )
                if !candidates.isEmpty {
                    // Keep the new endpoint out of the automatic add set
                    // until the user approves an old→new pairing. This
                    // preserves the no-guessing fallback when the dialog
                    // is skipped or the remove action is ignored.
                    reviewMoves.formUnion(candidates)
                    continue
                }
            }
            stageAddPaths.formUnion(untrackedPaths)
        }
    }

    for dirtyPath in event.dirtyPaths {
        if dirtyPath.kind == .renamed && dirtyPath.oldPath == nil {
            continue
        }
        if dirtyPath.kind == .renamed, let oldPath = dirtyPath.oldPath,
           let oldRelative = repositoryRelativeWorktreeEventPath(
               workdir: workdir,
               path: oldPath
           ),
           let newRelative = repositoryRelativeWorktreeEventPath(
               workdir: workdir,
               path: dirtyPath.path
           ) {
            let oldEntries = status.filter {
                $0.path == oldRelative || $0.path.hasPrefix("\(oldRelative)/")
            }
            let newEntries = status.filter {
                $0.path == newRelative || $0.path.hasPrefix("\(newRelative)/")
            }
            let oldDeleted = oldEntries.contains { $0.unstaged == .deleted }
            let newUntracked = newEntries.contains { $0.unstaged == .untracked }
            if oldRelative != newRelative,
               oldRelative.caseInsensitiveCompare(newRelative) == .orderedSame {
                guard oldDeleted && newUntracked else { continue }
                if !dirtyPath.isDirectory {
                    forceMoves.insert(
                        RepositoryExternalVCSMove(
                            oldPath: oldRelative,
                            newPath: newRelative
                        )
                    )
                }
            } else {
                guard oldDeleted || newUntracked else { continue }
                if newUntracked {
                    addPaths.formUnion(newEntries.filter {
                        $0.unstaged == .untracked
                    }.map(\.path))
                }
                if oldDeleted {
                    removePaths.formUnion(oldEntries.filter {
                        $0.unstaged == .deleted
                    }.map(\.path))
                }
            }
            continue
        }

        guard dirtyPath.kind == .created || dirtyPath.kind == .removed,
              let relative = repositoryRelativeWorktreeEventPath(
                  workdir: workdir,
                  path: dirtyPath.path
              ) else {
            continue
        }

        for entry in status where
            entry.path == relative || entry.path.hasPrefix("\(relative)/") {
            switch dirtyPath.kind {
            case .created where entry.unstaged == .untracked:
                stageAddPaths.insert(entry.path)
            case .removed where entry.unstaged == .deleted:
                removePaths.insert(entry.path)
            default:
                break
            }
        }
    }

    return RepositoryExternalVCSActionPaths(
        add: addPaths.sorted(),
        remove: removePaths.sorted(),
        stageAdd: stageAddPaths.sorted(),
        forceMove: forceMoves.sorted {
            if $0.oldPath != $1.oldPath { return $0.oldPath < $1.oldPath }
            return $0.newPath < $1.newPath
        },
        reviewMoves: reviewMoves.sorted {
            if $0.newPath != $1.newPath { return $0.newPath < $1.newPath }
            return $0.oldPath < $1.oldPath
        }
    )
}

func repositoryMonitorRootPaths(primary: String?, additional: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for rawPath in ([primary].compactMap { $0 } + additional) {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard !path.isEmpty, seen.insert(path).inserted else { continue }
        result.append(path)
    }
    return result
}

func nestedRepositoryRootPaths(rootPath: String, allRootPaths: [String]) -> [String] {
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : "\(root)/"
    return allRootPaths
        .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        .filter { $0 != root && $0.hasPrefix(prefix) }
        .sorted()
}

/// Returns the worktree-specific Git directory followed by its common Git
/// directory, when this is a linked worktree. IntelliJ watches both roots:
/// refs/tags/branches live in the common directory while HEAD/index and
/// operation markers live in the worktree directory.
func repositoryCommonGitDirectory(gitDir: URL) -> URL? {
    let worktreeGitDir = gitDir.standardizedFileURL.resolvingSymlinksInPath()
    let commondirURL = worktreeGitDir.appendingPathComponent("commondir")
    guard let raw = try? String(contentsOf: commondirURL, encoding: .utf8),
          let line = raw.split(whereSeparator: \.isNewline).first else {
        return nil
    }
    let commonPathString = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commonPathString.isEmpty else { return nil }
    let commonURL = URL(
        fileURLWithPath: commonPathString,
        relativeTo: worktreeGitDir
    ).standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(
        atPath: commonURL.path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else {
        return nil
    }
    guard commonURL.path != worktreeGitDir.path else { return nil }
    return commonURL
}

func repositoryMetadataRootPaths(gitDir: String) -> [String] {
    let worktreeGitDir = URL(fileURLWithPath: gitDir).standardizedFileURL
    return [worktreeGitDir.path]
        + (repositoryCommonGitDirectory(gitDir: worktreeGitDir).map { [$0.path] } ?? [])
}

/// Converts worktree VFS events into Git pathspecs. `nil` means that the
/// event cannot be safely scoped and callers should fall back to a full
/// status scan; an empty array means that the event only touched the
/// administrative path and does not invalidate worktree status.
func repositoryWorktreeStatusPaths(
    workdir: String,
    gitDir: String,
    dirtyPaths: [RepositoryDirtyPath]
) -> [String]? {
    guard !dirtyPaths.isEmpty else { return nil }
    let scope = repositoryDirtyScope(
        workdir: workdir,
        gitDir: gitDir,
        dirtyPaths: dirtyPaths
    ).compacted(workdir: workdir)
    guard !scope.everything else {
        return nil
    }
    let workdirPath = URL(fileURLWithPath: workdir).standardizedFileURL.path
    let gitDirPath = URL(fileURLWithPath: gitDir).standardizedFileURL.path
    let worktreePrefix = workdirPath.hasSuffix("/") ? workdirPath : "\(workdirPath)/"
    let gitDirPrefix = gitDirPath.hasSuffix("/") ? gitDirPath : "\(gitDirPath)/"
    var relativePaths = Set<String>()

    for path in scope.files + scope.directories + scope.nonRecursiveDirectories {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path == gitDirPath || path.hasPrefix(gitDirPrefix) {
            continue
        }
        guard path != workdirPath, path.hasPrefix(worktreePrefix) else {
            return nil
        }
        let relative = String(path.dropFirst(worktreePrefix.count))
        // A normal repository's `.git` entry is reported by the recursive
        // worktree stream as well as by the real gitDir stream. It must not be
        // passed to Git status as a worktree pathspec.
        if relative == ".git" || relative.hasPrefix(".git/") {
            continue
        }
        guard !relative.isEmpty else { return nil }
        relativePaths.insert(relative)
    }
    return relativePaths.sorted()
}

/// Converts paths reported by a Shelf/Apply Patch operation into the same
/// root-qualified dirty records used by the filesystem watcher. Shelf paths
/// are repository-relative in the engine, while imported patch callers may
/// already provide absolute paths; paths that escape the Git root are
/// rejected instead of widening an operation's refresh scope accidentally.
func repositoryShelfMutationDirtyPaths(
    workdir: String,
    paths: [String]
) -> [RepositoryDirtyPath] {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let rootPath = root.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    var seen = Set<String>()
    return paths.compactMap { rawPath in
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).standardizedFileURL
            : root.appendingPathComponent(trimmed).standardizedFileURL
        let normalized = candidate.path
        guard normalized != rootPath,
              normalized.hasPrefix(prefix),
              seen.insert(normalized).inserted else {
            return nil
        }
        return RepositoryDirtyPath(
            path: normalized,
            isDirectory: false,
            kind: .modified
        )
    }
    .sorted { $0.path < $1.path }
}

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
    private var fileSnapshots: [String: RepositoryFileSnapshot]

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
        self.fileSnapshots = repositoryFileSnapshots(
            rootPath: self.workdir,
            excludedRootPaths: self.excludedWorktreePaths
        )
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
            if scopes.contains(.worktree) {
                let currentSnapshots = repositoryFileSnapshots(
                    rootPath: self.workdir,
                    excludedRootPaths: self.excludedWorktreePaths
                )
                dirtyPaths = repositoryPairRenameEvents(
                    dirtyPaths: rawDirtyPaths,
                    previous: self.fileSnapshots,
                    current: currentSnapshots
                )
                self.fileSnapshots = currentSnapshots
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
        !context.excludedRootPaths.contains { excludedPath in
            let prefix = excludedPath.hasSuffix("/") ? excludedPath : "\(excludedPath)/"
            return dirtyPath.path == excludedPath || dirtyPath.path.hasPrefix(prefix)
        }
    }
    guard !dirtyPaths.isEmpty else { return }
    context.watcher?.eventReceived(scope: context.scope, paths: dirtyPaths)
}

/// Keeps the staging workspace and Git metadata caches synchronized with Git
/// processes outside Arbor.
///
/// IntelliJ receives recursive VFS events for both the worktree and the real
/// Git administrative directory. The engine's index revision remains as a
/// fallback because Git commonly replaces `.git/index` through `index.lock`.
struct RepositoryIndexRevisionMonitor: View {
    let repo: Repository?
    let repositoryID: String?
    let rootPaths: [String]
    let onChanged: (RepositoryChangeEvent) -> Void

    init(
        repo: Repository?,
        repositoryID: String?,
        rootPaths: [String] = [],
        onChanged: @escaping (RepositoryChangeEvent) -> Void
    ) {
        self.repo = repo
        self.repositoryID = repositoryID
        self.rootPaths = rootPaths
        self.onChanged = onChanged
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: repositoryID) {
                await monitor()
            }
    }

    private func monitor() async {
        var repositories: [(repo: Repository, workdir: String)] = []
        let primaryPath = repo?.workdir().map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        for normalized in repositoryMonitorRootPaths(primary: primaryPath, additional: rootPaths) {
            if normalized == primaryPath, let repo {
                repositories.append((repo, normalized))
                continue
            }
            guard let rootRepo = try? openRepository(path: normalized),
                  let workdir = rootRepo.workdir() else { continue }
            repositories.append((rootRepo, URL(fileURLWithPath: workdir).standardizedFileURL.path))
        }
        guard !repositories.isEmpty else { return }

        let watchers = repositories.map { item in
            RepositoryFileChangeWatcher(
                workdir: item.workdir,
                gitDir: item.repo.gitDir(),
                excludedWorktreePaths: nestedRepositoryRootPaths(
                    rootPath: item.workdir,
                    allRootPaths: repositories.map(\.workdir)
                ),
                onChange: onChanged
            )
        }
        watchers.forEach { $0.start() }
        defer { watchers.forEach { $0.stop() } }

        // Keep the revision array in the same order as `repositories`; a
        // task-group's completion order is not stable and could otherwise
        // attribute one root's index change to another root.
        var previous: [IndexRevision?] = []
        for item in repositories {
            previous.append(await Self.readRevision(item.repo))
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            for index in repositories.indices {
                guard !Task.isCancelled else { return }
                guard let baseline = previous[index] else {
                    previous[index] = await Self.readRevision(repositories[index].repo)
                    continue
                }

                let changed = await Self.indexChanged(repositories[index].repo, since: baseline)
                guard changed else { continue }

                // Advance before notifying. This coalesces the write burst
                // from Git's index.lock -> index replacement with FSEvent
                // callbacks while keeping the event root-qualified.
                previous[index] = await Self.readRevision(repositories[index].repo) ?? baseline
                watchers[index].notify(scope: .gitMetadata)
            }
        }
    }

    private static func readRevision(_ repo: Repository) async -> IndexRevision? {
        await Task.detached(priority: .utility) {
            try? repo.indexRevision()
        }.value
    }

    private static func indexChanged(_ repo: Repository, since revision: IndexRevision) async -> Bool {
        await Task.detached(priority: .utility) {
            (try? repo.indexChangedSince(previous: revision)) ?? false
        }.value
    }
}

/// Serializes automatic fetches for the same Git root when a project is open
/// in more than one window. Manual Git operations remain user-controlled; the
/// gate only prevents two background fetch loops from racing each other.
private actor GitAutoFetchCoordinator {
    static let shared = GitAutoFetchCoordinator()

    private var activeRoots: Set<String> = []

    func acquire(rootID: String) -> Bool {
        guard activeRoots.insert(rootID).inserted else { return false }
        return true
    }

    func release(rootID: String) {
        activeRoots.remove(rootID)
    }
}

/// Serializes Shelf lifecycle reads for the same Git root. Listing shelves can
/// finalize pending deletes and purge expired Recently Deleted entries, so two
/// project windows must not perform that file-backed migration concurrently.
private actor GitShelfLifecycleCoordinator {
    static let shared = GitShelfLifecycleCoordinator()

    private var activeRoots: Set<String> = []

    func acquire(rootID: String) -> Bool {
        guard activeRoots.insert(rootID).inserted else { return false }
        return true
    }

    func release(rootID: String) {
        activeRoots.remove(rootID)
    }
}

/// IntelliJ's incoming-change strategies run against every configured remote
/// for every Git root. FETCH refreshes local remote-tracking refs; LS_REMOTE
/// only checks the live remote and reports branches whose cached tracking ref
/// is stale. Transport failures still reach the common feedback surface.
func groupedAutoFetchValues(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
}

func normalizedGitRootPath(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    return URL(fileURLWithPath: path).standardizedFileURL.path
}

/// A root-qualified incoming branch is the SwiftUI equivalent of IntelliJ's
/// cached `GitBranchIncomingOutgoingManager` state. Keep the remote identity
/// separate from its display value so roots and remotes with similarly named
/// branches never get merged accidentally.
struct GitIncomingBranch: Hashable, Sendable {
    let rootPath: String
    let remote: String
    let branch: String

    init(rootPath: String, remote: String, branch: String) {
        self.rootPath = normalizedGitRootPath(rootPath)
        self.remote = remote
        self.branch = branch
    }

    var remoteBranch: String {
        "\(remote)/\(branch)"
    }

    var displayValue: String {
        "\(rootPath) · \(remoteBranch)"
    }
}

struct GitIncomingRemote: Hashable, Sendable {
    let rootPath: String
    let remote: String

    init(rootPath: String, remote: String) {
        self.rootPath = normalizedGitRootPath(rootPath)
        self.remote = remote
    }
}

/// Incoming state is a per-remote snapshot. Failed or contended remotes are
/// deliberately absent from `checkedRemotes`, so applying this result cannot
/// erase state that was not actually refreshed during this cycle.
struct GitIncomingBranchesSnapshot: Sendable {
    let branches: [GitIncomingBranch]
    let configuredRoots: Set<String>
    let configuredRemotes: Set<GitIncomingRemote>
    let checkedRemotes: Set<GitIncomingRemote>

    init(
        branches: [GitIncomingBranch],
        configuredRoots: Set<String> = [],
        configuredRemotes: Set<GitIncomingRemote> = [],
        checkedRemotes: Set<GitIncomingRemote> = [],
    ) {
        self.branches = groupedAutoFetchIncomingBranches(branches)
        self.configuredRoots = Set(configuredRoots.map(normalizedGitRootPath))
        self.configuredRemotes = Set(configuredRemotes.map {
            GitIncomingRemote(rootPath: $0.rootPath, remote: $0.remote)
        })
        self.checkedRemotes = Set(checkedRemotes.map {
            GitIncomingRemote(rootPath: $0.rootPath, remote: $0.remote)
        })
    }
}

func groupedAutoFetchIncomingBranches(_ values: [GitIncomingBranch]) -> [GitIncomingBranch] {
    Array(Set(values)).sorted {
        if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
        if $0.remote != $1.remote { return $0.remote < $1.remote }
        return $0.branch < $1.branch
    }
}

func hasUnfetchedIncomingBranch(
    rootPath: String?,
    branch: String,
    in values: Set<GitIncomingBranch>
) -> Bool {
    let normalizedRoot = normalizedGitRootPath(rootPath ?? "")
    return values.contains {
        $0.rootPath == normalizedRoot && $0.branch == branch
    }
}

func hasUnfetchedIncomingRemoteBranch(
    rootPath: String?,
    remote: String,
    branch: String,
    in values: Set<GitIncomingBranch>
) -> Bool {
    let normalizedRoot = normalizedGitRootPath(rootPath ?? "")
    return values.contains {
        $0.rootPath == normalizedRoot && $0.remote == remote && $0.branch == branch
    }
}

func applyingAutoFetchIncomingSnapshot(
    _ snapshot: GitIncomingBranchesSnapshot,
    to existing: Set<GitIncomingBranch>
) -> Set<GitIncomingBranch> {
    var result = existing.filter { branch in
        guard snapshot.configuredRoots.contains(branch.rootPath) else { return true }
        let remote = GitIncomingRemote(rootPath: branch.rootPath, remote: branch.remote)
        return snapshot.configuredRemotes.contains(remote)
            && !snapshot.checkedRemotes.contains(remote)
    }
    result.formUnion(snapshot.branches)
    return result
}

func autoFetchRemoteBranchIdentity(_ name: String) -> (remote: String, branch: String)? {
    guard let separator = name.firstIndex(of: "/") else { return nil }
    let remote = String(name[..<separator])
    let branchStart = name.index(after: separator)
    let branch = String(name[branchStart...])
    guard !remote.isEmpty, !branch.isEmpty else { return nil }
    return (remote, branch)
}

func mergedAutoFetchRootPaths(primary: String?, discovered: [String]) -> [String] {
    groupedAutoFetchValues([primary].compactMap { $0 } + discovered)
}

enum GitIncomingCheckSchedule {
    /// Equivalent to IntelliJ's `git.update.incoming.info.time` registry key.
    /// Keep this internal: IntelliJ exposes the value through Registry rather
    /// than the project Git settings UI.
    static let intervalMinutesKey = "arbor.git.incomingCheckIntervalMinutes.v1"
    static let defaultIntervalMinutes: UInt64 = 20

    static func intervalMinutes(defaults: UserDefaults = .standard) -> UInt64 {
        let configured = defaults.integer(forKey: intervalMinutesKey)
        guard configured > 0 else { return defaultIntervalMinutes }
        return UInt64(configured)
    }

    static func intervalSeconds(defaults: UserDefaults = .standard) -> UInt64 {
        intervalMinutes(defaults: defaults) * 60
    }
}

func autoFetchDelaySeconds(
    firstRun: Bool,
    defaults: UserDefaults = .standard
) -> UInt64? {
    // GitBranchIncomingOutgoingManager performs the first remote check when
    // the project is activated, then schedules the next check using the
    // Registry-configured minute interval. A retry starts a new task
    // generation, so it receives the same immediate first pass without a
    // separate one-shot boolean.
    firstRun ? nil : GitIncomingCheckSchedule.intervalSeconds(defaults: defaults)
}

func autoFetchRootFailure(rootPath: String, stage: String, error: Error) -> String {
    "\(rootPath) · \(stage): \(error.localizedDescription)"
}

func autoFetchNotificationFingerprint(_ values: [String]) -> String {
    groupedAutoFetchValues(values).joined(separator: "\n")
}

/// IntelliJ starts Shelf lifecycle maintenance immediately and repeats it
/// daily while the project is open. `nil` means run without an initial delay.
func shelfLifecycleDelaySeconds(firstRun: Bool) -> UInt64? {
    firstRun ? nil : 24 * 60 * 60
}

struct GitAutoFetchMonitor: View {
    let rootPaths: [String]
    let repositoryID: String
    let broker: CredentialBroker
    let strategy: GitIncomingCheckStrategy
    let tagMode: FetchTagsMode
    let onUpdated: ([String]) -> Void
    let onUnfetched: (GitIncomingBranchesSnapshot) -> Void
    let onFailure: ([String]) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: "\(repositoryID)|\(strategy.rawValue)|\(tagMode)") {
                await monitor()
            }
    }

    private func monitor() async {
        guard strategy != .none else { return }

        var firstRun = true
        // IntelliJ's incoming/outgoing manager starts each remote in
        // AuthenticationMode.NONE and promotes it to SILENT only after a
        // successful check. Keep this process-local set so a public remote
        // does not repeatedly take the no-auth path, while an explicit
        // interactive fetch can seed the same state through the broker.
        var silentRemotes: Set<String> = []
        while !Task.isCancelled {
            if let delay = autoFetchDelaySeconds(firstRun: firstRun) {
                do {
                    // Match the reference incoming-change service: the first
                    // check is immediate, subsequent checks use its cadence.
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            firstRun = false
            guard !Task.isCancelled else { return }

            var updatedRefs: [String] = []
            var unfetchedBranches: [GitIncomingBranch] = []
            var configuredRoots: Set<String> = []
            var configuredRemotes: Set<GitIncomingRemote> = []
            var checkedRemotes: Set<GitIncomingRemote> = []
            var failures: [String] = []
            let paths = mergedAutoFetchRootPaths(primary: nil, discovered: rootPaths)

            for rootPath in paths {
                guard !Task.isCancelled else { break }
                let repo: Repository
                do {
                    repo = try openRepository(path: rootPath)
                } catch {
                    failures.append(
                        autoFetchRootFailure(
                            rootPath: rootPath,
                            stage: "Open Git repository",
                            error: error
                        )
                    )
                    continue
                }

                let remotes: [RemoteInfo]
                do {
                    remotes = try repo.remoteList()
                } catch {
                    failures.append(
                        autoFetchRootFailure(
                            rootPath: rootPath,
                            stage: "Load Git remotes",
                            error: error
                        )
                    )
                    continue
                }
                configuredRoots.insert(normalizedGitRootPath(rootPath))
                configuredRemotes.formUnion(remotes.map {
                    GitIncomingRemote(rootPath: rootPath, remote: $0.name)
                })
                guard !remotes.isEmpty else {
                    continue
                }

                let rootID = repo.gitDir()
                guard await GitAutoFetchCoordinator.shared.acquire(rootID: rootID) else {
                    continue
                }

                var rootUpdatedRefs: [String] = []
                var rootUnfetchedBranches: [GitIncomingBranch] = []
                var rootFailures: [String] = []
                for remote in remotes {
                    guard !Task.isCancelled else { break }
                    let cancel = GitCancelHandle()
                    let remoteKey = "\(normalizedGitRootPath(rootPath))|\(remote.name)"
                    let useSilentAuth = silentRemotes.contains(remoteKey)
                        || broker.hasSuccessfulAuthentication(remoteUrl: remote.url)
                    let operation = Task.detached(priority: .utility) {
                        switch strategy {
                        case .none:
                            return (updated: [String](), unfetched: [String]())
                        case .fetch:
                            let outcome: FetchOutcome = if useSilentAuth {
                                try repo.fetchWithOptionsAndSilentAuthAndCancel(
                                    remote: remote.name,
                                    tagMode: tagMode,
                                    broker: broker,
                                    cancel: cancel
                                )
                            } else {
                                try repo.fetchWithOptionsWithoutAuthAndCancel(
                                    remote: remote.name,
                                    tagMode: tagMode,
                                    cancel: cancel
                                )
                            }
                            return (updated: outcome.updated, unfetched: [String]())
                        case .lsRemote:
                            let branches: [String] = if useSilentAuth {
                                try repo.remoteIncomingBranchesWithSilentAuthAndCancel(
                                    remote: remote.name,
                                    broker: broker,
                                    cancel: cancel
                                )
                            } else {
                                try repo.remoteIncomingBranchesWithoutAuthAndCancel(
                                    remote: remote.name,
                                    cancel: cancel
                                )
                            }
                            return (updated: [String](), unfetched: branches)
                        }
                    }

                    do {
                        let outcome = try await withTaskCancellationHandler(operation: {
                            try await operation.value
                        }, onCancel: {
                            cancel.cancel()
                        })
                        silentRemotes.insert(remoteKey)
                        rootUpdatedRefs.append(contentsOf: outcome.updated.map {
                            "\(remote.name)/\($0)"
                        })
                        checkedRemotes.insert(GitIncomingRemote(rootPath: rootPath, remote: remote.name))
                        rootUnfetchedBranches.append(contentsOf: outcome.unfetched.map {
                            GitIncomingBranch(
                                rootPath: rootPath,
                                remote: remote.name,
                                branch: $0
                            )
                        })
                    } catch is CancellationError {
                        cancel.cancel()
                        operation.cancel()
                        break
                    } catch {
                        rootFailures.append("\(rootPath) · \(remote.name): \(error.localizedDescription)")
                    }
                }

                await GitAutoFetchCoordinator.shared.release(rootID: rootID)
                updatedRefs.append(contentsOf: rootUpdatedRefs)
                unfetchedBranches.append(contentsOf: rootUnfetchedBranches)
                failures.append(contentsOf: rootFailures)
            }

            guard !Task.isCancelled else { return }
            let groupedUpdatedRefs = groupedAutoFetchValues(updatedRefs)
            let incomingSnapshot = GitIncomingBranchesSnapshot(
                branches: unfetchedBranches,
                configuredRoots: configuredRoots,
                configuredRemotes: configuredRemotes,
                checkedRemotes: checkedRemotes,
            )
            let groupedFailures = groupedAutoFetchValues(failures)
            if !groupedUpdatedRefs.isEmpty {
                await MainActor.run {
                    onUpdated(groupedUpdatedRefs)
                }
            }
            await MainActor.run {
                // Publish the complete snapshot, including an empty one, so
                // a later clean check clears IntelliJ-style stale incoming
                // state and its notification.
                onUnfetched(incomingSnapshot)
            }
            await MainActor.run {
                // Failures are also a cycle snapshot. An empty result clears
                // an error from a previous cycle after recovery.
                onFailure(groupedFailures)
            }
        }
    }
}

/// Keeps Shelf lifecycle maintenance independent from the visible Shelf panel.
/// The Rust list APIs perform the same startup convergence and seven-day
/// Recently Deleted cleanup as IntelliJ's ShelveChangesManager; this monitor
/// makes that behavior happen even when the user never opens the Shelf view.
struct GitShelfLifecycleMonitor: View {
    let rootPaths: [String]
    let repositoryID: String

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: repositoryID) {
                await monitor()
            }
    }

    private func monitor() async {
        var firstRun = true
        while !Task.isCancelled {
            if let delay = shelfLifecycleDelaySeconds(firstRun: firstRun) {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            firstRun = false
            guard !Task.isCancelled else { return }

            for rootPath in mergedAutoFetchRootPaths(primary: nil, discovered: rootPaths) {
                guard !Task.isCancelled,
                      let repo = try? openRepository(path: rootPath) else { continue }
                let rootID = repo.gitDir()
                guard await GitShelfLifecycleCoordinator.shared.acquire(rootID: rootID) else {
                    continue
                }
                // Both calls are intentionally retained: shelveList finalizes
                // pending deletes, while shelveDeletedList applies the
                // seven-day Recently Deleted cutoff.
                _ = try? repo.shelveList()
                _ = try? repo.shelveDeletedList()
                await GitShelfLifecycleCoordinator.shared.release(rootID: rootID)
            }
        }
    }
}
