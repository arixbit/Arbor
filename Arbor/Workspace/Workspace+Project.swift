import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// IntelliJ's GitInit asks before re-initializing a directory that is already
/// inside a Git worktree. Resolve the owning worktree before starting `git
/// init`, including when the user selected a subdirectory of that worktree.
func gitInitializationExistingRepositoryRoot(path: String) -> String? {
    guard let repository = try? openRepository(path: path),
          let root = repository.workdir(),
          !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: root).standardizedFileURL.path
}
/// Prepare the root reword without changing the generated merge-preserving
/// todo order or any of its topology markers.
func preparedRootRewordTodo(
    _ todo: RebaseTodo,
    rootCommitID: String,
    message: String
) -> RebaseTodo? {
    let rootCommitID = rootCommitID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootCommitID.isEmpty else { return nil }

    var prepared = todo
    guard let targetIndex = prepared.items.firstIndex(where: { item in
        item.commitId == rootCommitID
            || item.commitId.hasPrefix(rootCommitID)
            || rootCommitID.hasPrefix(item.commitId)
    }) else {
        return nil
    }
    prepared.items[targetIndex].action = .reword
    prepared.items[targetIndex].message = message
    return prepared
}
/// A display-only status snapshot used to make the Commit workspace useful
/// immediately after relaunch. Git status remains authoritative: the snapshot
/// is replaced as soon as the fresh scan completes and is never used to decide
/// whether a Git operation is safe.
struct PersistedStatusCacheEntry: Codable, Equatable, Sendable {
    static let currentSchema = 1

    struct File: Codable, Equatable, Sendable {
        let path: String
        let oldPath: String?
        let staged: String
        let unstaged: String

        init(_ entry: FileEntry) {
            path = entry.path
            oldPath = entry.oldPath
            staged = persistedChangeKind(entry.staged)
            unstaged = persistedChangeKind(entry.unstaged)
        }

        var fileEntry: FileEntry? {
            guard let staged = changeKind(rawValue: staged),
                  let unstaged = changeKind(rawValue: unstaged) else {
                return nil
            }
            return FileEntry(
                path: path,
                oldPath: oldPath,
                staged: staged,
                unstaged: unstaged
            )
        }
    }

    struct ChangeList: Codable, Equatable, Sendable {
        let name: String
        let paths: [String]
        let isDefault: Bool
        let isActive: Bool

        init(_ list: ChangeListInfo) {
            name = list.name
            paths = list.paths
            isDefault = list.isDefault
            isActive = list.isActive
        }

        var changeListInfo: ChangeListInfo {
            ChangeListInfo(
                name: name,
                paths: paths,
                isDefault: isDefault,
                isActive: isActive
            )
        }
    }

    let schema: Int
    let rootPath: String
    let savedAt: Date
    let files: [File]
    let changeLists: [ChangeList]

    init(
        rootPath: String,
        files: [FileEntry],
        changeLists: [ChangeListInfo],
        savedAt: Date = Date()
    ) {
        schema = Self.currentSchema
        self.rootPath = canonicalExternalLogPath(rootPath)
        self.savedAt = savedAt
        self.files = files.map(File.init)
        self.changeLists = changeLists.map(ChangeList.init)
    }

    func restoredSnapshot(
        rootPath: String
    ) -> (files: [FileEntry], changeLists: [ChangeListInfo])? {
        guard schema == Self.currentSchema,
              self.rootPath == canonicalExternalLogPath(rootPath) else {
            return nil
        }
        return (
            files: files.compactMap(\.fileEntry),
            changeLists: changeLists.map(\.changeListInfo)
        )
    }
}
let persistedStatusCacheKeyPrefix = "arbor.vcs-status-cache.v1."
let persistedStatusCacheFilePrefix = "arbor-vcs-status-v1-"
let persistedStatusCacheMaximumBytes = 4 * 1024 * 1024
let persistedStatusCacheMaximumFiles = 20_000
let persistedStatusCacheWriteQueue = DispatchQueue(
    label: "com.arbor.vcs-status-cache",
    qos: .utility
)
func persistedStatusCacheFileURL(rootPath: String) -> URL? {
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
        .appendingPathComponent("Arbor/VCSStatus", isDirectory: true)
        .appendingPathComponent(persistedStatusCacheFilePrefix + encoded)
        .appendingPathExtension("json")
}
/// The status snapshot is display-only and can be discarded during migration.
/// Keeping it in UserDefaults makes the entire preferences domain expensive to
/// load when a large repository has many changed files.
func migrateLegacyPersistedStatusCaches(defaults: UserDefaults = .standard) {
    let legacyKeys = defaults.dictionaryRepresentation().keys.filter {
        $0.hasPrefix(persistedStatusCacheKeyPrefix)
    }
    for key in legacyKeys {
        defaults.removeObject(forKey: key)
    }
}
func loadPersistedStatusCache(rootPath: String) -> PersistedStatusCacheEntry? {
    guard let url = persistedStatusCacheFileURL(rootPath: rootPath),
          let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let fileSize = resourceValues.fileSize,
          fileSize <= persistedStatusCacheMaximumBytes,
          let data = try? Data(contentsOf: url) else {
        return nil
    }
    return try? JSONDecoder().decode(PersistedStatusCacheEntry.self, from: data)
}
func savePersistedStatusCache(
    rootPath: String,
    files: [FileEntry],
    changeLists: [ChangeListInfo]
) {
    guard files.count <= persistedStatusCacheMaximumFiles else { return }
    persistedStatusCacheWriteQueue.async {
        let entry = PersistedStatusCacheEntry(
            rootPath: rootPath,
            files: files,
            changeLists: changeLists
        )
        guard let url = persistedStatusCacheFileURL(rootPath: entry.rootPath),
              let data = try? JSONEncoder().encode(entry),
              data.count <= persistedStatusCacheMaximumBytes else {
            // A repository with millions of changed files is not a useful
            // startup snapshot. Avoid serializing it into any persistent store.
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            // A cache write must never make a Git operation fail.
        }
    }
}
