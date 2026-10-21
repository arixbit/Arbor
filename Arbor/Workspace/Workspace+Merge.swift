import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A rollback action is meaningful only when the merge actually moved HEAD.
func mergeRollbackHead(initial: String?, final: String?) -> String? {
    guard let initial, let final, initial != final else { return nil }
    return initial
}
struct MultiRootMergeDeleteCandidate: Equatable {
    let rootPath: String
    let displayName: String
}
/// Keep the confirmation target set root-qualified and deterministic. The
/// semantic action may be invoked after a refresh or relaunch, so callers must
/// re-resolve the roots instead of trusting the snapshot captured at merge
/// completion.
func multiRootMergeDeleteTargets(
    selectedRootPaths: Set<String>,
    candidates: [MultiRootMergeDeleteCandidate]
) -> [MultiRootMergeDeleteCandidate] {
    let normalizedSelectedPaths = Set(selectedRootPaths.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    })
    var seen = Set<String>()
    return candidates
        .filter { candidate in
            let normalizedRoot = URL(fileURLWithPath: candidate.rootPath).standardizedFileURL.path
            return normalizedSelectedPaths.contains(normalizedRoot) && seen.insert(normalizedRoot).inserted
        }
        .sorted {
            let lhs = URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path
            let rhs = URL(fileURLWithPath: $1.rootPath).standardizedFileURL.path
            if lhs != rhs { return lhs < rhs }
            return $0.displayName < $1.displayName
        }
}
/// A Smart/Force retry only reruns roots blocked by local changes. Keep the
/// first pass's other root results and replace just the retried roots, matching
/// IntelliJ's aggregate reset result instead of collapsing the operation view
/// to the retry subset.
func mergeRootOperationResults(
    preserved: [RootOperationResult],
    retry: [RootOperationResult],
    rootOrder: [String]
) -> [RootOperationResult] {
    mergeResultsByRoot(preserved: preserved, retry: retry, rootOrder: rootOrder, rootPath: \.rootPath)
}
/// Multi-root Merge needs to retain more than the display row when Smart
/// retrying: initial/final HEAD and pending/conflict state drive the rollback
/// surface after the retry. Replace only retried roots while preserving the
/// complete first-pass result for every other root.
func mergeMultiRootMergeResults(
    preserved: [MultiRootMergeResult],
    retry: [MultiRootMergeResult],
    rootOrder: [String]
) -> [MultiRootMergeResult] {
    mergeResultsByRoot(preserved: preserved, retry: retry, rootOrder: rootOrder, rootPath: \.rootPath)
}

private func mergeResultsByRoot<Result>(
    preserved: [Result],
    retry: [Result],
    rootOrder: [String],
    rootPath: KeyPath<Result, String>
) -> [Result] {
    var byRoot = Dictionary(uniqueKeysWithValues: preserved.map { ($0[keyPath: rootPath], $0) })
    retry.forEach { byRoot[$0[keyPath: rootPath]] = $0 }
    var orderedPaths = rootOrder
    orderedPaths.append(contentsOf: byRoot.keys.filter { !orderedPaths.contains($0) }.sorted())
    return orderedPaths.compactMap { byRoot[$0] }
}
/// Merge command-filter results from multiple Git roots without allowing
/// identical object ids to collapse across repositories. A single-root
/// command keeps Git's emitted order; aggregate commands use the same stable
/// time/root/id ordering as the aggregate Log table and clear graph lanes that
/// would otherwise imply parent edges between unrelated repositories.
func mergedLogCommandEntries(
    _ entriesByRoot: [[CommitInfo]],
    limit: Int,
    aggregate: Bool
) -> [CommitInfo] {
    guard limit > 0 else { return [] }
    var entries = entriesByRoot.flatMap { $0 }
    if aggregate {
        entries = entries.map { commit in
            var flattened = commit
            flattened.lane = 0
            flattened.parentLanes = []
            return flattened
        }.sorted {
            if $0.time != $1.time { return $0.time > $1.time }
            let leftRoot = $0.repositoryPath ?? ""
            let rightRoot = $1.repositoryPath ?? ""
            if leftRoot != rightRoot { return leftRoot < rightRoot }
            return $0.id < $1.id
        }
    }
    var seen = Set<String>()
    return entries.filter { commit in
        let key = "\(commit.repositoryPath ?? "")\u{1f}\(commit.id)"
        return seen.insert(key).inserted
    }.prefix(limit).map { $0 }
}
