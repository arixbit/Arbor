import CoreServices
import SwiftUI


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

/// Build products and IDE metadata can contain hundreds of thousands of
/// files. They are not useful Git worktree events and must not trigger a
/// repository-wide rename snapshot.
private let repositoryGeneratedDirectoryNames: Set<String> = [
    ".build",
    ".gradle",
    ".swiftpm",
    "DerivedData",
    "target",
    "xcuserdata"
]

private func repositoryIsGeneratedWorktreePathLexically(
    _ path: String,
    rootPath: String
) -> Bool {
    let root = rootPath
    let candidate = path
    let prefix = root.hasSuffix("/") ? root : "\(root)/"
    guard candidate.hasPrefix(prefix) else { return false }
    let relative = String(candidate.dropFirst(prefix.count))
    return relative
        .split(separator: "/")
        .contains { component in
            let name = String(component)
            return repositoryGeneratedDirectoryNames.contains(name)
                || name.hasPrefix(".build")
        }
}

func repositoryIsGeneratedWorktreePath(_ path: String, rootPath: String) -> Bool {
    repositoryIsGeneratedWorktreePathLexically(
        URL(fileURLWithPath: path).standardizedFileURL.path,
        rootPath: URL(fileURLWithPath: rootPath).standardizedFileURL.path
    )
}

func repositoryShouldIgnoreGeneratedWorktreeEvent(
    scope: RepositoryChangeScope,
    path: String,
    rootPath: String,
    kind: RepositoryDirtyChangeKind = .modified,
    oldPath: String? = nil
) -> Bool {
    guard scope.contains(.worktree),
          repositoryIsGeneratedWorktreePath(path, rootPath: rootPath) else {
        return false
    }
    guard kind == .renamed else { return true }
    guard let oldPath else {
        // An unpaired rename may have originated outside the generated tree.
        return false
    }
    return repositoryIsGeneratedWorktreePath(oldPath, rootPath: rootPath)
}

/// Git's transient lock files never contain user-visible repository state.
/// A read-only query such as `git status` may briefly create
/// `.git/index.lock`; delivering that event as a metadata change would start
/// the same refresh that produced it, again and again. Lock files are only
/// coordination artifacts, so the watcher drops them.
func repositoryShouldIgnoreGitMetadataEvent(
    scope: RepositoryChangeScope,
    path: String
) -> Bool {
    guard scope.contains(.gitMetadata) else { return false }
    return URL(fileURLWithPath: path).pathExtension == "lock"
}

/// Captures stable filesystem identities without reading file contents. The
/// device/inode pair survives an ordinary rename, while independently created
/// files do not share it. This lets the watcher recover the old endpoint that
/// FSEvents omits, without guessing from names or timestamps.
///
/// Uses `stat()` rather than `FileManager.attributesOfItem(atPath:)`: the
/// Foundation call also materialises every extended attribute, so a walk of a
/// large worktree becomes hundreds of thousands of `getxattr` syscalls.
func repositoryFileSnapshot(atPath path: String) -> RepositoryFileSnapshot? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return RepositoryFileSnapshot(
        identity: "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))",
        isDirectory: (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    )
}

/// Enumerates a worktree once. Callers that must stay cheap per event keep a
/// snapshot cache instead of calling this on every batch; `deadline` bounds
/// the occasional cold start on very large repositories.
func repositoryFileSnapshots(
    rootPath: String,
    excludedRootPaths: [String] = [],
    maxEntries: Int? = nil,
    deadline: Date? = nil
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
    var visited = 0
    for case let url as URL in enumerator {
        visited &+= 1
        if visited & 0xff == 0, let deadline, Date() >= deadline {
            break
        }
        let path = url.standardizedFileURL.path
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory == true
        if isDirectory && (
            url.lastPathComponent == ".git"
                || repositoryIsGeneratedWorktreePathLexically(path, rootPath: root.path)
        ) {
            enumerator.skipDescendants()
            continue
        }
        if excluded.contains(where: { excludedPath in
            path == excludedPath || path.hasPrefix(excludedPath + "/")
        }) {
            if isDirectory {
                enumerator.skipDescendants()
            }
            continue
        }

        guard let snapshot = repositoryFileSnapshot(atPath: path) else {
            continue
        }
        snapshots[path] = snapshot
        if let maxEntries, snapshots.count >= maxEntries {
            break
        }
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
