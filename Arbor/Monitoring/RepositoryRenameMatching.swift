import CoreServices
import SwiftUI


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
