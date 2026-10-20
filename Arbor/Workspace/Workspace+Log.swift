import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The first response only needs to fill the visible history viewport.
/// Continuation pages stay larger so scrolling remains efficient.
let initialLogPageLimit: UInt32 = 80
let continuationLogPageLimit: UInt32 = 200
struct PersistedLogCacheEntry: Codable, Equatable, Sendable {
    static let currentSchema = 2

    let schema: Int
    let rootPath: String
    let queryFingerprint: String
    let refsToken: String
    let commits: [PersistedLogCacheCommit]

    init(
        rootPath: String,
        queryFingerprint: String,
        refsToken: String,
        commits: [CommitInfo]
    ) {
        schema = Self.currentSchema
        self.rootPath = canonicalExternalLogPath(rootPath)
        self.queryFingerprint = queryFingerprint
        self.refsToken = refsToken
        self.commits = commits.map(PersistedLogCacheCommit.init)
    }

    func restoredCommitsIfValid(
        rootPath: String,
        queryFingerprint: String,
        refsToken: String
    ) -> [CommitInfo]? {
        guard schema == Self.currentSchema,
              self.rootPath == canonicalExternalLogPath(rootPath),
              self.queryFingerprint == queryFingerprint,
              self.refsToken == refsToken else {
            return nil
        }
        return commits.map(\.commitInfo)
    }
}
/// A root-scoped continuation snapshot for the visible VCS Log graph. Unlike
/// the first-paint cache above, this records every page the user has already
/// loaded, together with the exact continuation cursor and whether Git still
/// has more rows. It is a validated display/index snapshot only: refsToken
/// must match before it is restored, and Git remains the source of truth when
/// the repository graph has changed.
struct PersistedLogGraphEntry: Codable, Equatable, Sendable {
    static let currentSchema = 1

    let schema: Int
    let rootPath: String
    let queryFingerprint: String
    let refsToken: String
    let commits: [PersistedLogCacheCommit]
    let cursor: String?
    let hasMore: Bool

    init(
        rootPath: String,
        queryFingerprint: String,
        refsToken: String,
        commits: [CommitInfo],
        cursor: String?,
        hasMore: Bool
    ) {
        schema = Self.currentSchema
        self.rootPath = canonicalExternalLogPath(rootPath)
        self.queryFingerprint = queryFingerprint
        self.refsToken = refsToken
        self.commits = commits.map(PersistedLogCacheCommit.init)
        self.cursor = cursor
        self.hasMore = hasMore
    }

    func restoredIfValid(
        rootPath: String,
        queryFingerprint: String,
        refsToken: String
    ) -> PersistedLogGraphRestore? {
        guard schema == Self.currentSchema,
              self.rootPath == canonicalExternalLogPath(rootPath),
              self.queryFingerprint == queryFingerprint,
              self.refsToken == refsToken,
              !hasMore || cursor != nil else {
            return nil
        }
        return PersistedLogGraphRestore(
            commits: commits.map(\.commitInfo),
            cursor: cursor,
            hasMore: hasMore
        )
    }
}
struct PersistedLogCacheQuery: Codable, Equatable, Sendable {
    let rootPath: String
    let pathFilters: [String]
    let startRevisions: [String]
    let author: String
    let message: String
    let messageRegex: Bool
    let messageMatchCase: Bool
    let since: String
    let until: String
    let noMerges: Bool
    let follow: Bool
    let sortMode: String
    let pageLimit: UInt32
}
func persistedLogCacheQueryFingerprint(
    rootPath: String,
    pathFilters: [String],
    startRevisions: [String],
    author: String,
    message: String,
    messageRegex: Bool,
    messageMatchCase: Bool,
    since: String,
    until: String,
    noMerges: Bool,
    follow: Bool,
    sortMode: String,
    pageLimit: UInt32
) -> String {
    let query = PersistedLogCacheQuery(
        rootPath: canonicalExternalLogPath(rootPath),
        pathFilters: pathFilters,
        startRevisions: startRevisions,
        author: author,
        message: message,
        messageRegex: messageRegex,
        messageMatchCase: messageMatchCase,
        since: since,
        until: until,
        noMerges: noMerges,
        follow: follow,
        sortMode: sortMode,
        pageLimit: pageLimit
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(query) else { return "" }
    return data.base64EncodedString()
}
/// Graph snapshots survive page-size changes. The visible page size is a UI
/// batching detail, not part of the Git Log query identity.
func persistedLogGraphQueryFingerprint(
    rootPath: String,
    pathFilters: [String],
    startRevisions: [String],
    author: String,
    message: String,
    messageRegex: Bool,
    messageMatchCase: Bool,
    since: String,
    until: String,
    noMerges: Bool,
    follow: Bool,
    sortMode: String
) -> String {
    persistedLogCacheQueryFingerprint(
        rootPath: rootPath,
        pathFilters: pathFilters,
        startRevisions: startRevisions,
        author: author,
        message: message,
        messageRegex: messageRegex,
        messageMatchCase: messageMatchCase,
        since: since,
        until: until,
        noMerges: noMerges,
        follow: follow,
        sortMode: sortMode,
        pageLimit: 0
    )
}
struct PersistedLogRefsToken: Codable, Equatable, Sendable {
    let rootPath: String
    let headID: String
    let localBranches: [String]
    let remoteBranches: [String]
    let tags: [String]

    init(repo: Repository, rootPath: String) throws {
        self.rootPath = canonicalExternalLogPath(rootPath)
        headID = repo.headCommitId() ?? ""
        let refSnapshot = try repo.refTipSnapshot()
        localBranches = refSnapshot
            .filter { $0.hasPrefix("local\u{1f}") }
            .sorted()
        remoteBranches = refSnapshot
            .filter { $0.hasPrefix("remote\u{1f}") }
            .sorted()
        tags = refSnapshot
            .filter { $0.hasPrefix("tag\u{1f}") }
            .sorted()
    }
}
func persistedLogRefsToken(repo: Repository, rootPath: String) -> String? {
    guard let data = try? JSONEncoder().encode(
        PersistedLogRefsToken(repo: repo, rootPath: rootPath)
    ) else {
        return nil
    }
    return data.base64EncodedString()
}
let persistedLogCacheKeyPrefix = "arbor.vcs-log-cache.v2."
let persistedLogGraphKeyPrefix = "arbor.vcs-log-graph.v1."
let persistedLogGraphFilePrefix = "arbor-vcs-log-graph-v1-"
let persistedLogGraphWriteQueue = DispatchQueue(
    label: "com.arbor.vcs-log-graph-cache",
    qos: .utility
)
func persistedLogCacheKey(rootPath: String) -> String {
    let encoded = Data(canonicalExternalLogPath(rootPath).utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return persistedLogCacheKeyPrefix + encoded
}
func persistedLogGraphKey(rootPath: String) -> String {
    let encoded = Data(canonicalExternalLogPath(rootPath).utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return persistedLogGraphKeyPrefix + encoded
}
func persistedLogGraphURL(rootPath: String) -> URL? {
    guard let cachesURL = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    ).first else {
        return nil
    }
    let encoded = Data(canonicalExternalLogPath(rootPath).utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return cachesURL
        .appendingPathComponent("Arbor/VCSLogGraph", isDirectory: true)
        .appendingPathComponent(persistedLogGraphFilePrefix + encoded)
        .appendingPathExtension("json")
}
func loadPersistedLogCache(rootPath: String) -> PersistedLogCacheEntry? {
    guard let data = UserDefaults.standard.data(
        forKey: persistedLogCacheKey(rootPath: rootPath)
    ) else {
        return nil
    }
    return try? JSONDecoder().decode(PersistedLogCacheEntry.self, from: data)
}
func savePersistedLogCache(_ entry: PersistedLogCacheEntry) {
    guard let data = try? JSONEncoder().encode(entry) else { return }
    UserDefaults.standard.set(data, forKey: persistedLogCacheKey(rootPath: entry.rootPath))
}
func loadPersistedLogGraph(rootPath: String) -> PersistedLogGraphEntry? {
    if let url = persistedLogGraphURL(rootPath: rootPath),
       let data = try? Data(contentsOf: url),
       let entry = try? JSONDecoder().decode(PersistedLogGraphEntry.self, from: data) {
        return entry
    }
    // Read the previous UserDefaults representation once as a migration
    // fallback. New writes are disk-backed so large histories do not inflate
    // the application's preferences domain.
    guard let data = UserDefaults.standard.data(
        forKey: persistedLogGraphKey(rootPath: rootPath)
    ) else {
        return nil
    }
    return try? JSONDecoder().decode(PersistedLogGraphEntry.self, from: data)
}
func savePersistedLogGraph(_ entry: PersistedLogGraphEntry) {
    persistedLogGraphWriteQueue.async {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        if let url = persistedLogGraphURL(rootPath: entry.rootPath) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
                return
            } catch {
                // A cache write must never make the Git Log operation fail.
                // Fall back to the legacy store if the cache directory is not
                // writable (for example in a restricted test container).
            }
        }
        UserDefaults.standard.set(data, forKey: persistedLogGraphKey(rootPath: entry.rootPath))
    }
}
/// Mirrors IntelliJ's CopyRevisionNumberAction: revision numbers are copied
/// from the oldest selected row to the newest, separated by spaces so the
/// result can be pasted directly into a native Git command.
func formattedRevisionIDsForClipboard(_ ids: [String]) -> String {
    ids.reversed().joined(separator: " ")
}
/// Log date fields accept calendar dates. Keep epoch seconds as a
/// backwards-compatible input, matching IntelliJ's persisted date filter.
func parseLogDate(_ value: String) -> Int64? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    if let seconds = Int64(normalized) { return seconds }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: normalized) {
            return Int64(date.timeIntervalSince1970)
        }
    }
    return nil
}
/// Return Git's explicit max-count value when it is numeric. Options after
/// `--` are pathspecs and must not affect command-log paging.
func gitLogCommandMaximum(_ arguments: [String]) -> Int? {
    let options = arguments.prefix { $0 != "--" }
    for (index, argument) in options.enumerated() {
        if argument.hasPrefix("--max-count=") {
            return Int(argument.dropFirst("--max-count=".count))
        }
        if argument == "--max-count" || argument == "-n" {
            guard index + 1 < options.count else { return nil }
            return Int(options[index + 1])
        }
        if argument.hasPrefix("-n") {
            return Int(argument.dropFirst(2))
        }
        if argument.count > 1,
           argument.first == "-",
           Int(argument.dropFirst()) != nil {
            return Int(argument.dropFirst())
        }
    }
    return nil
}
/// IntelliJ's command filter keeps collecting until the command itself
/// imposes a maximum. Recognize the common Git spellings so command Log can
/// expose the same load-more behavior instead of treating the first page as
/// the complete result.
func gitLogCommandHasExplicitLimit(_ arguments: [String]) -> Bool {
    let options = arguments.prefix { $0 != "--" }
    return options.contains { argument in
        argument == "--max-count"
            || argument.hasPrefix("--max-count=")
            || argument == "-n"
            || (argument.hasPrefix("-n") && Int(argument.dropFirst(2)) != nil)
            || (argument.count > 1
                && argument.first == "-"
                && Int(argument.dropFirst()) != nil)
    }
}
func hostedFileRevisionTarget(
    for record: LogChangeRecord
) -> (commitID: String, path: String) {
    if record.change.kind == .deleted,
       let parentIndex = record.parentIndex,
       record.commit.parentIds.indices.contains(Int(parentIndex)) {
        return (
            record.commit.parentIds[Int(parentIndex)],
            record.change.path
        )
    }
    return (record.commit.id, record.change.path)
}
func hostedFileRevisionLink(
    repository: Repository,
    remoteURL: String,
    commitID: String,
    path: String
) -> String? {
    guard !path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
        return nil
    }
    return repository.permalinkForPath(
        remoteUrl: remoteURL,
        commitId: commitID,
        path: path
    )
}
