import CoreServices
import SwiftUI


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
