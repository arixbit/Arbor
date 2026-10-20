import CoreServices
import SwiftUI


/// IntelliJ's VcsVFSListener keeps independent confirmation policies for
/// files added to and removed from version control. `ask` is the safe default;
/// `perform` mirrors DO_ACTION_SILENTLY and `ignore` mirrors
/// DO_NOTHING_SILENTLY.
enum GitVFSListenerAction: String, CaseIterable, Identifiable, Sendable {
    case ask
    case perform
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask for confirmation"
        case .perform: "Perform silently"
        case .ignore: "Do nothing"
        }
    }
}

enum GitVFSListenerSettings {
    static let addActionKey = "arbor.git.vfsListener.addAction.v1"
    static let removeActionKey = "arbor.git.vfsListener.removeAction.v1"

    static func addAction(defaults: UserDefaults = .standard) -> GitVFSListenerAction {
        action(forKey: addActionKey, defaults: defaults)
    }

    static func removeAction(defaults: UserDefaults = .standard) -> GitVFSListenerAction {
        action(forKey: removeActionKey, defaults: defaults)
    }

    static func setAddAction(
        _ action: GitVFSListenerAction,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(action.rawValue, forKey: addActionKey)
    }

    static func setRemoveAction(
        _ action: GitVFSListenerAction,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(action.rawValue, forKey: removeActionKey)
    }

    private static func action(
        forKey key: String,
        defaults: UserDefaults
    ) -> GitVFSListenerAction {
        guard let rawValue = defaults.string(forKey: key),
              let action = GitVFSListenerAction(rawValue: rawValue) else {
            return .ask
        }
        return action
    }
}

struct RepositoryExternalVCSActionPaths: Equatable, Sendable {
    let add: [String]
    /// Newly created worktree files use IntelliJ staging-area's empty-blob
    /// index path. Rename destinations remain in `add` because IntelliJ's
    /// move/rename action stages their complete content.
    let stageAdd: [String]
    let remove: [String]
    let forceMove: [RepositoryExternalVCSMove]
    /// Rename candidates whose old endpoint could not be proven from the
    /// filesystem identity. They require an explicit user choice.
    let reviewMoves: [RepositoryExternalVCSMove]

    var isEmpty: Bool {
        add.isEmpty
            && stageAdd.isEmpty
            && remove.isEmpty
            && forceMove.isEmpty
            && reviewMoves.isEmpty
    }

    init(
        add: [String],
        remove: [String],
        stageAdd: [String] = [],
        forceMove: [RepositoryExternalVCSMove] = [],
        reviewMoves: [RepositoryExternalVCSMove] = []
    ) {
        self.add = add
        self.stageAdd = stageAdd
        self.remove = remove
        self.forceMove = forceMove
        self.reviewMoves = reviewMoves
    }
}

struct RepositoryExternalVCSMove: Codable, Equatable, Hashable, Sendable {
    let oldPath: String
    let newPath: String
}

enum RepositoryExternalVCSPathKind: String, Codable, Sendable {
    case missing
    case file
    case directory
    case symbolicLink
    case other
}

struct RepositoryExternalVCSPathSnapshot: Codable, Equatable, Sendable {
    let path: String
    let kind: RepositoryExternalVCSPathKind
    let byteCount: UInt64?
    let digest: String?

    var isVerifiable: Bool {
        switch kind {
        case .missing, .directory:
            true
        case .file, .symbolicLink:
            digest != nil
        case .other:
            false
        }
    }
}

/// The exact paths a user approved for an external VFS Git action. Keeping
/// this separate from the raw watcher event makes Retry replay only confirmed
/// work, never an unreviewed rename candidate.
struct RepositoryExternalVCSAction: Codable, Equatable, Sendable {
    let addPaths: [String]
    let stageAddPaths: [String]
    let removePaths: [String]
    let forceMoves: [RepositoryExternalVCSMove]
    let pathSnapshots: [RepositoryExternalVCSPathSnapshot]

    init(
        addPaths: [String],
        stageAddPaths: [String],
        removePaths: [String],
        forceMoves: [RepositoryExternalVCSMove],
        pathSnapshots: [RepositoryExternalVCSPathSnapshot] = []
    ) {
        self.addPaths = addPaths
        self.stageAddPaths = stageAddPaths
        self.removePaths = removePaths
        self.forceMoves = forceMoves
        self.pathSnapshots = pathSnapshots
    }

    private enum CodingKeys: String, CodingKey {
        case addPaths
        case stageAddPaths
        case removePaths
        case forceMoves
        case pathSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addPaths = try container.decode([String].self, forKey: .addPaths)
        stageAddPaths = try container.decode([String].self, forKey: .stageAddPaths)
        removePaths = try container.decode([String].self, forKey: .removePaths)
        forceMoves = try container.decode([RepositoryExternalVCSMove].self, forKey: .forceMoves)
        pathSnapshots = try container.decodeIfPresent(
            [RepositoryExternalVCSPathSnapshot].self,
            forKey: .pathSnapshots
        ) ?? []
    }

    var isEmpty: Bool {
        addPaths.isEmpty
            && stageAddPaths.isEmpty
            && removePaths.isEmpty
            && forceMoves.isEmpty
    }
}

func repositoryExternalVCSActionPathIsSafe(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    return !path.hasPrefix("/")
        && !components.isEmpty
        && !components.contains(".")
        && !components.contains("..")
        && !path.contains("\\")
        && !components.contains(".git")
}

func repositoryExternalVCSActionIsSafe(
    _ action: RepositoryExternalVCSAction
) -> Bool {
    let paths = action.addPaths + action.stageAddPaths + action.removePaths
    return paths.allSatisfy(repositoryExternalVCSActionPathIsSafe)
        && action.forceMoves.allSatisfy {
            repositoryExternalVCSActionPathIsSafe($0.oldPath)
                && repositoryExternalVCSActionPathIsSafe($0.newPath)
        }
}

/// Keep an explicitly selected rename set one-to-one. Ambiguous directory
/// matching can produce several old endpoints for one destination (or the
/// same old endpoint for several destinations); applying either conflict as a
/// Git add/remove pair would not be a rename and could remove unrelated index
/// entries.
func repositoryNonConflictingExternalVCSMoves(
    _ moves: [RepositoryExternalVCSMove]
) -> [RepositoryExternalVCSMove] {
    var oldPaths = Set<String>()
    var newPaths = Set<String>()
    return moves.filter { move in
        guard oldPaths.insert(move.oldPath).inserted,
              newPaths.insert(move.newPath).inserted else {
            return false
        }
        return true
    }
}

/// Applies the user's per-path selection while preserving the action order
/// and removing duplicate endpoints from a coalesced VFS batch.
func repositorySelectedExternalVCSPaths(
    paths: [String],
    selected: Set<String>
) -> [String] {
    var seen = Set<String>()
    return paths.filter { selected.contains($0) && seen.insert($0).inserted }
}

/// Converts worktree events into the exact paths that IntelliJ's
/// GitVFSListener would offer to add/remove. Existing modified files are
/// deliberately excluded from the add set; ignored files are also excluded
/// because their status is not `Untracked`. Case-only moves are kept as a
/// separate force-move action.
func repositoryExternalVCSActionPaths(
    event: RepositoryChangeEvent,
    workdir: String,
    status: [FileEntry],
    contentRenameMatches: [RepositoryExternalVCSMove] = []
) -> RepositoryExternalVCSActionPaths {
    var addPaths = Set<String>()
    var stageAddPaths = Set<String>()
    var removePaths = Set<String>()
    var forceMoves = Set<RepositoryExternalVCSMove>()
    var reviewMoves = Set<RepositoryExternalVCSMove>()

    let trustedContentMoves = repositoryNonConflictingExternalVCSMoves(
        contentRenameMatches
    ).filter { move in
        let isEventRename = event.dirtyPaths.contains { dirtyPath in
            guard dirtyPath.kind == .renamed,
                  dirtyPath.oldPath == nil,
                  !dirtyPath.isDirectory,
                  let newPath = repositoryRelativeWorktreeEventPath(
                      workdir: workdir,
                      path: dirtyPath.path
                  ) else {
                return false
            }
            return newPath == move.newPath
        }
        return isEventRename
            && status.contains {
                $0.path == move.newPath && $0.unstaged == .untracked
            }
            && status.contains {
                $0.path == move.oldPath && $0.unstaged == .deleted
            }
    }
    let contentMatchedNewPaths = Set(trustedContentMoves.map(\.newPath))
    addPaths.formUnion(trustedContentMoves.map(\.newPath))
    removePaths.formUnion(trustedContentMoves.map(\.oldPath))

    for dirtyPath in event.dirtyPaths where
        dirtyPath.kind == .renamed && dirtyPath.oldPath == nil {
        guard let relative = repositoryRelativeWorktreeEventPath(
            workdir: workdir,
            path: dirtyPath.path
        ) else { continue }
        let newEntries = status.filter {
            $0.path == relative || $0.path.hasPrefix("\(relative)/")
        }
        // If Git's own full status scan gives one unambiguous rename record,
        // its oldPath is authoritative even though FSEvents omitted it.
        // A directory that remains unpaired can produce several records and
        // is intentionally kept on the conservative new-file path below.
        let detectedPairs = newEntries.compactMap { entry -> (String, String)? in
            guard entry.path == relative,
                  let oldPath = entry.oldPath,
                  entry.staged == .renamed || entry.unstaged == .renamed else {
                return nil
            }
            return (oldPath, entry.path)
        }
        if detectedPairs.count == 1,
           let (oldPath, newPath) = detectedPairs.first {
            if !dirtyPath.isDirectory,
               oldPath != newPath,
               oldPath.caseInsensitiveCompare(newPath) == .orderedSame {
                forceMoves.insert(
                    RepositoryExternalVCSMove(
                        oldPath: oldPath,
                        newPath: newPath
                    )
                )
            } else {
                addPaths.insert(newPath)
                removePaths.insert(oldPath)
            }
        } else {
            if contentMatchedNewPaths.contains(relative) {
                continue
            }
            let untrackedPaths = newEntries
                .filter { $0.unstaged == .untracked }
                .map(\.path)
            if dirtyPath.isDirectory {
                let candidates = repositoryAmbiguousDirectoryRenameCandidates(
                    directoryPath: relative,
                    newEntries: newEntries,
                    status: status
                )
                reviewMoves.formUnion(candidates)
                let reviewedNewPaths = Set(candidates.map(\.newPath))
                stageAddPaths.formUnion(
                    untrackedPaths.filter { !reviewedNewPaths.contains($0) }
                )
                continue
            }
            // FSEvents can report a rename without its old endpoint, and Git
            // can then expose the same move as one deleted tracked path plus
            // one untracked destination instead of a rename record. A
            // singleton deleted path is not identity evidence: it may be an
            // unrelated deletion in the same status batch. Only plausible
            // basename matches go through explicit move review; all other
            // destinations keep the conservative new-file fallback.
            let deletedPaths = status
                .filter { $0.unstaged == .deleted }
                .map(\.path)
            if untrackedPaths.count == 1,
               let newPath = untrackedPaths.first {
                let candidates = repositoryAmbiguousFileRenameCandidates(
                    newPath: newPath,
                    deletedPaths: deletedPaths
                )
                if !candidates.isEmpty {
                    // Keep the new endpoint out of the automatic add set
                    // until the user approves an old→new pairing. This
                    // preserves the no-guessing fallback when the dialog
                    // is skipped or the remove action is ignored.
                    reviewMoves.formUnion(candidates)
                    continue
                }
            }
            stageAddPaths.formUnion(untrackedPaths)
        }
    }

    for dirtyPath in event.dirtyPaths {
        if dirtyPath.kind == .renamed && dirtyPath.oldPath == nil {
            continue
        }
        if dirtyPath.kind == .renamed, let oldPath = dirtyPath.oldPath,
           let oldRelative = repositoryRelativeWorktreeEventPath(
               workdir: workdir,
               path: oldPath
           ),
           let newRelative = repositoryRelativeWorktreeEventPath(
               workdir: workdir,
               path: dirtyPath.path
           ) {
            let oldEntries = status.filter {
                $0.path == oldRelative || $0.path.hasPrefix("\(oldRelative)/")
            }
            let newEntries = status.filter {
                $0.path == newRelative || $0.path.hasPrefix("\(newRelative)/")
            }
            let oldDeleted = oldEntries.contains { $0.unstaged == .deleted }
            let newUntracked = newEntries.contains { $0.unstaged == .untracked }
            if oldRelative != newRelative,
               oldRelative.caseInsensitiveCompare(newRelative) == .orderedSame {
                guard oldDeleted && newUntracked else { continue }
                if !dirtyPath.isDirectory {
                    forceMoves.insert(
                        RepositoryExternalVCSMove(
                            oldPath: oldRelative,
                            newPath: newRelative
                        )
                    )
                }
            } else {
                guard oldDeleted || newUntracked else { continue }
                if newUntracked {
                    addPaths.formUnion(newEntries.filter {
                        $0.unstaged == .untracked
                    }.map(\.path))
                }
                if oldDeleted {
                    removePaths.formUnion(oldEntries.filter {
                        $0.unstaged == .deleted
                    }.map(\.path))
                }
            }
            continue
        }

        guard dirtyPath.kind == .created || dirtyPath.kind == .removed,
              let relative = repositoryRelativeWorktreeEventPath(
                  workdir: workdir,
                  path: dirtyPath.path
              ) else {
            continue
        }

        for entry in status where
            entry.path == relative || entry.path.hasPrefix("\(relative)/") {
            switch dirtyPath.kind {
            case .created where entry.unstaged == .untracked:
                stageAddPaths.insert(entry.path)
            case .removed where entry.unstaged == .deleted:
                removePaths.insert(entry.path)
            default:
                break
            }
        }
    }

    return RepositoryExternalVCSActionPaths(
        add: addPaths.sorted(),
        remove: removePaths.sorted(),
        stageAdd: stageAddPaths.sorted(),
        forceMove: forceMoves.sorted {
            if $0.oldPath != $1.oldPath { return $0.oldPath < $1.oldPath }
            return $0.newPath < $1.newPath
        },
        reviewMoves: reviewMoves.sorted {
            if $0.newPath != $1.newPath { return $0.newPath < $1.newPath }
            return $0.oldPath < $1.oldPath
        }
    )
}
