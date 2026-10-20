import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Partitions selected Changes Browser rows into the commit/parent patches
/// needed by IntelliJ's Apply/Revert actions. A root may contain several
/// selected commits, but one merge commit cannot mix parent diffs in the same
/// patch action. The root-qualified commit key keeps equal object IDs from
/// different repositories independent, so a cross-root selection can be
/// executed sequentially with each repository's own patch snapshot.
func logChangePatchGroups(_ records: [LogChangeRecord]) -> [[LogChangeRecord]] {
    guard !records.isEmpty else { return [] }

    var groups: [[LogChangeRecord]] = []
    var groupIndexByKey: [String: Int] = [:]
    var parentKeyByCommit: [String: String] = [:]

    for record in records {
        let parentKey = record.parentIndex.map(String.init) ?? "root"
        let rootKey = record.commit.repositoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? ""
        let commitKey = "\(rootKey)\u{1f}\(record.commit.id)"
        if let existingParentKey = parentKeyByCommit[commitKey], existingParentKey != parentKey {
            return []
        }
        parentKeyByCommit[commitKey] = parentKey

        let groupKey = "\(commitKey)\u{1f}\(parentKey)"
        if let index = groupIndexByKey[groupKey] {
            guard !groups[index].contains(where: { $0.change.path == record.change.path }) else {
                return []
            }
            groups[index].append(record)
        } else {
            groupIndexByKey[groupKey] = groups.count
            groups.append([record])
        }
    }
    return groups
}

func canApplyLogChangeSelection(_ records: [LogChangeRecord]) -> Bool {
    !logChangePatchGroups(records).isEmpty
}

/// Create Patch consumes the selected Changes as one patch file. A path may
/// not occur twice in that file: two revisions of the same path would require
/// commit ordering metadata that a plain Git patch does not carry. Renames
/// contribute both endpoints so the generated patch keeps the rename pair.
func canCreateLogPatchSelection(_ records: [LogChangeRecord]) -> Bool {
    let groups = logChangePatchGroups(records)
    guard !groups.isEmpty else { return false }

    var seenPaths = Set<String>()
    for record in groups.flatMap({ $0 }) {
        for path in [record.change.oldPath, record.change.path].compactMap({ $0 }) {
            guard !path.isEmpty, seenPaths.insert(path).inserted else {
                return false
            }
        }
    }
    return true
}

struct LogPatchGitCommand: Equatable {
    let command: String
    let args: [String]
}

/// Keeps revision arguments and pathspec arguments in the exact order needed
/// by Git. In particular, `--` must precede every selected path, and a merge
/// Changes row must use the parent that produced that row.
func logPatchGitCommand(
    commit: CommitInfo,
    parentIndex: UInt32?,
    paths: [String]
) -> LogPatchGitCommand? {
    guard !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }) else { return nil }
    if let parentIndex {
        let index = Int(parentIndex)
        guard commit.parentIds.indices.contains(index) else { return nil }
        return LogPatchGitCommand(
            command: "diff",
            args: [
                "--binary",
                "--no-ext-diff",
                commit.parentIds[index],
                commit.id,
                "--"
            ] + paths
        )
    }

    return LogPatchGitCommand(
        command: "show",
        args: [
            "--format=",
            "--binary",
            "--no-ext-diff",
            "--root",
            commit.id,
            "--"
        ] + paths
    )
}
