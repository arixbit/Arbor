import SwiftUI
import AppKit
import UniformTypeIdentifiers

func branchCreateAndRebaseShouldCreateBranch(
    branchAlreadyExists: Bool,
    resetExisting: Bool
) -> Bool {
    !branchAlreadyExists || resetExisting
}
func pullDialogDefaultRebase(
    explicit: Bool?,
    savedOptions: Set<GitPullDialogOption>
) -> Bool {
    explicit ?? savedOptions.contains(.rebase)
}
func multiRootPullRebaseMode(_ operation: MultiRootOperation) -> Bool? {
    switch operation {
    case .pullMerge:
        false
    case .pullRebase:
        true
    default:
        nil
    }
}
func rebaseRangeRequestIsCurrent(
    generation: Int,
    currentGeneration: Int,
    requestedOnto: String,
    currentOnto: String,
    requestedPreserveMerges: Bool,
    currentPreserveMerges: Bool,
    requestedRoot: Bool = false,
    currentRoot: Bool = false,
    requestedBranch: String = "",
    currentBranch: String = "",
    requestedRepositoryPath: String = "",
    currentRepositoryPath: String = ""
) -> Bool {
    generation == currentGeneration
        && requestedOnto == currentOnto
        && requestedPreserveMerges == currentPreserveMerges
        && requestedRoot == currentRoot
        && requestedBranch == currentBranch
        && requestedRepositoryPath == currentRepositoryPath
}
func rebaseUndoTargetAfterCompletion(
    seed: RebaseUndoSeed?,
    currentBranch: String?,
    finalHead: String?
) -> RebaseUndoTarget? {
    let currentBranchIdentity = currentBranch ?? ""
    guard let seed,
          !seed.updateRefs,
          currentBranchIdentity == seed.branch,
          let finalHead,
          finalHead != seed.initialHead else { return nil }
    return RebaseUndoTarget(
        repositoryPath: seed.repositoryPath,
        branch: seed.branch,
        initialHead: seed.initialHead,
        expectedHead: finalHead,
        protectionCommitID: seed.protectionCommitID
    )
}
func rebaseUndoSeedKey(repositoryPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.rebase.undo-seed.v1.\(encoded)"
}
func saveRebaseUndoSeed(_ seed: RebaseUndoSeed) {
    guard let data = try? JSONEncoder().encode(seed) else { return }
    UserDefaults.standard.set(data, forKey: rebaseUndoSeedKey(repositoryPath: seed.repositoryPath))
}
func loadRebaseUndoSeed(repositoryPath: String) -> RebaseUndoSeed? {
    guard let data = UserDefaults.standard.data(forKey: rebaseUndoSeedKey(repositoryPath: repositoryPath)) else {
        return nil
    }
    return try? JSONDecoder().decode(RebaseUndoSeed.self, from: data)
}
func clearRebaseUndoSeed(repositoryPath: String) {
    UserDefaults.standard.removeObject(forKey: rebaseUndoSeedKey(repositoryPath: repositoryPath))
}
func rebaseRecoveryNotificationID(repositoryPath: String) -> String {
    let stablePath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.rebase-recovery.\(stablePath)"
}
func rebaseUndoNotificationID(repositoryPath: String) -> String {
    let stablePath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.rebase-undo.\(stablePath)"
}
func makeRebaseUndoSeed(
    repo: Repository,
    branch: String,
    onto: String? = nil
) -> RebaseUndoSeed? {
    guard let repositoryPath = repo.workdir(),
          !repositoryPath.isEmpty,
          let initialHead = try? repo.revisionCommitId(revision: branch) else { return nil }
    return RebaseUndoSeed(
        repositoryPath: repositoryPath,
        branch: branch,
        initialHead: initialHead,
        updateRefs: false,
        protectionCommitID: onto.flatMap {
            rebaseUndoProtectionCommitBeforeOperation(
                repo: repo,
                initialHead: initialHead,
                onto: $0
            )
        }
    )
}
/// Capture IntelliJ's firstChangedHash boundary before a rebase rewrites refs.
/// This helper is global because seeds are also created by nonisolated
/// operation setup paths outside the ContentView extension.
func rebaseUndoProtectionCommitBeforeOperation(
    repo: Repository,
    initialHead: String,
    onto: String
) -> String? {
    let normalizedOnto = onto.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedOnto.isEmpty,
          let ontoID = try? repo.revisionCommitId(revision: normalizedOnto),
          ontoID != initialHead,
          let base = try? repo.mergeBaseRevisionId(
              first: initialHead,
              second: ontoID
          ),
          let commits = try? repo.logWithCommand(
              commandArgs: ["--reverse", "\(base)..\(initialHead)"],
              limit: 1
          ) else {
        return nil
    }
    return commits.first?.id
}
