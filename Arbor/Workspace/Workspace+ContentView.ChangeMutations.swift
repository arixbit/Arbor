import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

struct MultiRootChangeMutationFailure: Sendable {
    let path: PersistedMultiRootChangePath
    let message: String
}

func runMultiRootChangeMutation(
    operation: ArborVCSActionRequest.MultiRootRetryOperation,
    paths: [PersistedMultiRootChangePath]
) {
    let normalizedPaths = normalizedMultiRootChangePaths(paths)
    guard !normalizedPaths.isEmpty else {
        feedbackCenter.warning(
            operation == .stage ? "No changes selected for staging" : "No changes selected for unstaging"
        )
        return
    }

    let rootPaths = Array(Set(normalizedPaths.map(\.rootPath))).sorted()
    let notificationID = multiRootChangesBatchMutationNotificationID(
        operation: operation,
        changePaths: normalizedPaths
    )
    let operationTitle = operation == .stage ? "Stage selected changes" : "Unstage selected changes"
    beginFeedbackOperation(operationTitle, notificationID: notificationID)

    Task.detached(priority: .userInitiated) {
        var completed: [PersistedMultiRootChangePath] = []
        var failures: [MultiRootChangeMutationFailure] = []
        let pathsByRoot = Dictionary(grouping: normalizedPaths, by: \.rootPath)

        for rootPath in rootPaths {
            do {
                let rootRepo = try openRepository(path: rootPath)
                for change in pathsByRoot[rootPath, default: []] {
                    do {
                        switch operation {
                        case .stage:
                            try rootRepo.stage(path: change.path)
                        case .unstage:
                            try rootRepo.unstage(path: change.path)
                        default:
                            continue
                        }
                        completed.append(change)
                    } catch {
                        failures.append(
                            MultiRootChangeMutationFailure(
                                path: change,
                                message: errorMessage(error)
                            )
                        )
                    }
                }
            } catch {
                let message = errorMessage(error)
                failures.append(contentsOf: pathsByRoot[rootPath, default: []].map {
                    MultiRootChangeMutationFailure(path: $0, message: message)
                })
            }
        }

        let completedPaths = completed
        let failurePaths = failures
        await MainActor.run { [completedPaths, failurePaths] in
            self.loadMultiRootChanges()
            let verb = operation == .stage ? "staged" : "unstaged"
            if failurePaths.isEmpty {
                self.feedbackCenter.success(
                    "Selected changes \(verb)",
                    detail: "\(completedPaths.count) file(s) across \(rootPaths.count) Git root(s)",
                    notificationID: notificationID
                )
                return
            }

            let failureDetail = failurePaths.map {
                "\($0.path.rootPath): \($0.path.path)\n\($0.message)"
            }.joined(separator: "\n")
            let nextStep = "Fix the failed files, then retry only the remaining selected paths."
            if completedPaths.isEmpty {
                self.feedbackCenter.error(
                    "Selected changes failed to \(operation == .stage ? "stage" : "unstage")",
                    detail: failureDetail,
                    nextStep: nextStep,
                    additionalActions: [
                        self.multiRootChangesBatchRetryFeedbackAction(
                            operation: operation,
                            changePaths: failurePaths.map(\.path)
                        )
                    ],
                    notificationID: notificationID
                )
            } else {
                self.feedbackCenter.warning(
                    "Selected changes partially \(verb)",
                    detail: "\(completedPaths.count) succeeded;\n\(failureDetail)",
                    nextStep: nextStep,
                    additionalActions: [
                        self.multiRootChangesBatchRetryFeedbackAction(
                            operation: operation,
                            changePaths: failurePaths.map(\.path)
                        )
                    ],
                    notificationID: notificationID
                )
            }
        }
    }
}

func validateMultiRootRenameName(_ value: String) -> String? {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return nil }
    guard candidate != branchWorkspace.multiRootRenameOldName else {
        return localizedArborString("The new name must be different.", locale: AppLanguage.interfaceLocale)
    }
    let selected = multiRootWorkspace.branchSnapshots.filter { snapshot in
        branchWorkspace.multiRootRenameSelectedRootPaths.contains(snapshot.rootPath)
            && snapshot.branches.contains(where: { $0.name == branchWorkspace.multiRootRenameOldName })
    }
    for snapshot in selected {
        if let conflict = branchRenameConflictMessage(
            oldName: branchWorkspace.multiRootRenameOldName,
            newName: candidate,
            localBranchNames: snapshot.branches.map(\.name),
            remoteBranchNames: snapshot.remoteBranches.map(\.name)
        ) {
            return "\(conflict) (\(snapshot.relativePath))"
        }
        guard let rootRepo = try? openRepository(path: snapshot.rootPath) else { continue }
        do {
            try rootRepo.validateBranchName(name: candidate)
        } catch {
            return errorMessage(error)
        }
    }
    return nil
}

func normalizedMultiRootChangePaths(
    _ paths: [PersistedMultiRootChangePath]
) -> [PersistedMultiRootChangePath] {
    var seen = Set<String>()
    return paths
        .filter { !$0.rootPath.isEmpty && !$0.path.isEmpty }
        .filter { seen.insert("\($0.rootPath)\u{1f}\($0.path)").inserted }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.path < $1.path }
            return $0.rootPath < $1.rootPath
        }
}

nonisolated func dirtyPathsForSmartDecision(_ repo: Repository) throws -> [String] {
    try repo.status()
        .filter {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
        .map(\.path)
}

func validateSingleRootRenameName(rootPath: String, oldName: String, value: String) -> String? {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return nil }
    guard let snapshot = multiRootWorkspace.branchSnapshots.first(where: { $0.rootPath == rootPath }) else {
        return "The selected Git root is no longer available."
    }
    if let conflict = branchRenameConflictMessage(
        oldName: oldName,
        newName: candidate,
        localBranchNames: snapshot.branches.map(\.name),
        remoteBranchNames: snapshot.remoteBranches.map(\.name)
    ) {
        return conflict
    }
    guard let rootRepo = try? openRepository(path: rootPath) else {
        return "The selected Git root could not be opened."
    }
    do {
        try rootRepo.validateBranchName(name: candidate)
        return nil
    } catch {
        return errorMessage(error)
    }
}

/// Capture the saved-artifact identity before a multi-root preserving
/// operation. The engine intentionally keeps the artifact on disk when a
/// restore conflicts; comparing object/name sets lets the notification point
/// at that exact root-scoped artifact without relying on stash index 0.
nonisolated static func savedChangeIDsByRoot(
    rootPaths: [String]
) -> (stashes: [String: Set<String>], shelves: [String: Set<String>]) {
    var stashes: [String: Set<String>] = [:]
    var shelves: [String: Set<String>] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
        if let entries = try? rootRepo.stashList() {
            stashes[rootPath] = Set(entries.map(\.id))
        }
        if let entries = try? rootRepo.shelveList() {
            shelves[rootPath] = Set(entries.map(\.name))
        }
    }
    return (stashes, shelves)
}

nonisolated static func newSavedChangeIDsByRoot(
    rootPaths: [String],
    before: (stashes: [String: Set<String>], shelves: [String: Set<String>]),
    stashMessagePrefix: String,
    shelfNamePrefix: String
) -> (stashes: [String: String], shelves: [String: String]) {
    var stashes: [String: String] = [:]
    var shelves: [String: String] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
        if let beforeStashes = before.stashes[rootPath],
           let entries = try? rootRepo.stashList(),
           let stash = entries.first(where: {
               !beforeStashes.contains($0.id) && $0.message.hasPrefix(stashMessagePrefix)
           }) {
            stashes[rootPath] = stash.id
        }
        if let beforeShelves = before.shelves[rootPath],
           let entries = try? rootRepo.shelveList(),
           let shelf = entries.first(where: {
               !beforeShelves.contains($0.name) && $0.name.hasPrefix(shelfNamePrefix)
           }) {
            shelves[rootPath] = shelf.name
        }
    }
    return (stashes, shelves)
}

}
