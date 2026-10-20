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

func repositoryEventKey(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
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

func mergedRepositoryDirtyPath(
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
