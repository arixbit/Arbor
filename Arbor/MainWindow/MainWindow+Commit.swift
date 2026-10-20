import SwiftUI
import AppKit


/// IntelliJ's cherry-picked highlighter only decorates commits after its
/// branch-aware comparison succeeds. A pending, empty, or failed comparison
/// must not fall back to commit-message trailers, which can mark unrelated
/// commits as picked.
func isCherryPickedCommitHighlighted(
    highlightingEnabled: Bool,
    comparisonReady: Bool,
    identity: String,
    highlightedCommitIDs: Set<String>
) -> Bool {
    highlightingEnabled
        && comparisonReady
        && highlightedCommitIDs.contains(identity)
}

struct PendingInitialCommitRewrite {
    let commits: [CommitInfo]
    let action: RebaseTodoAction
}

/// Returns the single Git root that owns a Log selection. Aggregate Log
/// actions must use this identity before reading root-scoped remotes or
/// opening a write dialog; a raw commit hash is not sufficient when two roots
/// contain the same object id.
func logCommitSelectionRepositoryPath(_ commits: [CommitInfo]) -> String? {
    guard let first = commits.first,
          let repositoryPath = first.repositoryPath,
          !repositoryPath.isEmpty,
          commits.allSatisfy({ $0.repositoryPath == repositoryPath }) else {
        return nil
    }
    return repositoryPath
}

struct LogCommitRootBatch {
    let rootPath: String
    let commits: [CommitInfo]
}

/// IntelliJ's GitApplyChangesProcess groups a Log selection by owning Git
/// root before applying Cherry-pick/Revert. Preserve first-seen root order and
/// the Log UI order within each root so aggregate history never collapses
/// equal object IDs or sends a commit to the wrong repository.
func logCommitRootBatches(_ commits: [CommitInfo]) -> [LogCommitRootBatch] {
    var batches: [LogCommitRootBatch] = []
    var indexByRoot: [String: Int] = [:]
    for commit in commits {
        guard let rootPath = logReferenceRootPath(for: commit) else { continue }
        if let index = indexByRoot[rootPath] {
            batches[index] = LogCommitRootBatch(
                rootPath: rootPath,
                commits: batches[index].commits + [commit]
            )
        } else {
            indexByRoot[rootPath] = batches.count
            batches.append(LogCommitRootBatch(rootPath: rootPath, commits: [commit]))
        }
    }
    return batches
}

/// The project-level Commit workflow exposes only commit-eligible staged
/// paths, while retaining conflict/no-staged state for explicit feedback.
struct MultiRootCommitGroup: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let stagedPaths: [String]
    let stagedEntries: [MultiRootChangeSelection]
    let conflictedPaths: [String]
    let hasHead: Bool

    var id: String { rootPath }
    func canCommit(amend: Bool) -> Bool {
        conflictedPaths.isEmpty && (!stagedPaths.isEmpty || (amend && hasHead))
    }

    init(changeGroup: MultiRootChangeGroup) {
        rootPath = changeGroup.rootPath
        displayName = changeGroup.displayName
        relativePath = changeGroup.relativePath
        hasHead = changeGroup.repository.headCommitId() != nil
        stagedPaths = changeGroup.entries
            .filter {
                $0.staged != .unchanged
                    && $0.staged != .conflicted
                    && $0.staged != .ignored
            }
            .map(\.path)
            .sorted()
        stagedEntries = changeGroup.entries
            .filter {
                $0.staged != .unchanged
                    && $0.staged != .conflicted
                    && $0.staged != .ignored
            }
            .map {
                MultiRootChangeSelection(
                    rootPath: changeGroup.rootPath,
                    path: $0.path,
                    oldPath: $0.oldPath
                )
            }
            .sorted { $0.path < $1.path }
        conflictedPaths = changeGroup.entries
            .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
            .map(\.path)
            .sorted()
    }
}

struct BeforeCommitCommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var command: String
    var args: [String]

    var display: String {
        ([command] + args).joined(separator: " ")
    }
}
