import CoreServices
import SwiftUI


private func isRepositoryPath(_ path: String, isSameOrDescendantOf ancestor: String) -> Bool {
    guard path != ancestor else { return true }
    if ancestor == "/" {
        return path.hasPrefix("/")
    }
    return path.hasPrefix(ancestor + "/")
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

        // Avoid normalizing every path in a large single-directory burst. The
        // lexical check preserves the same promotion rule while avoiding a
        // pathological Foundation URL walk on older macOS runners.
        let lexicalRoot: String
        if workdir.count > 1 && workdir.last == "/" {
            lexicalRoot = String(workdir.dropLast())
        } else {
            lexicalRoot = workdir
        }
        if directories.isEmpty,
           nonRecursiveDirectories.isEmpty,
           files.count >= Self.rootDirtyFolderSizeThreshold,
           let firstFile = files.first {
            let commonParent = Self.lexicalParent(firstFile)
            var allFilesShareParent = true
            for file in files where Self.lexicalParent(file) != commonParent {
                allFilesShareParent = false
                break
            }
            if commonParent != lexicalRoot,
               commonParent.hasPrefix(lexicalRoot + "/"),
               allFilesShareParent {
                return RepositoryDirtyScope(
                    files: [],
                    directories: [commonParent],
                    nonRecursiveDirectories: [],
                    everything: false
                )
            }
        }

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
                var parent = Self.lexicalParent(path)
                while isRepositoryPath(parent, isSameOrDescendantOf: root), parent != root {
                    descendantCounts[parent, default: 0] += 1
                    parent = Self.lexicalParent(parent)
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
            var parent = lexicalParent(path)
            var covered = false
            while !parent.isEmpty {
                if retained.contains(parent) {
                    covered = true
                    break
                }
                let next = lexicalParent(parent)
                if next == parent { break }
                parent = next
            }
            if !covered {
                retained.insert(path)
            }
        }
        return retained
    }

    private static func lexicalParent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
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
