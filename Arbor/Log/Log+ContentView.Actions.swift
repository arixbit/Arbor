import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


var logActionAvailability: LogActionAvailability {
    LogActionAvailability(
        hasLocalChanges: hasLocalChanges,
        activeOperationRootPath: operationRecovery.operation == nil ? nil : repo?.workdir(),
        hasRemotes: !remoteWorkspace.remotes.isEmpty
    )
}


/// Route menu-level graph actions through a changing command identity so
/// repeated Collapse/Expand requests are delivered even when their action type
/// is unchanged.
func issueLogGraphCommand(_ action: LinearBekGraphActionType) {
    logRuntime.graphCommand = LinearBekGraphCommand(
        id: (logRuntime.graphCommand?.id ?? 0) + 1,
        action: action
    )
}


/// Mirrors IntelliJ's windowed VCS Log status loader. Signature verification
/// is deliberately not part of the main log query: GPG/SSH verification can
/// be slow or unavailable, so only the currently loaded rows request a
/// cancellable background batch and stale generations are discarded.
func loadLogSignatureStatuses() {
    guard logShowSignatureColumn, logList.viewMode == .graph else {
        logRuntime.signatureLoadTask?.cancel()
        logRuntime.signatureLoadingIDs.removeAll()
        logRuntime.signatureFailedIDs.removeAll()
        return
    }

    let commits = logList.entries
    guard !commits.isEmpty else {
        logRuntime.signatureLoadTask?.cancel()
        logRuntime.signatureLoadingIDs.removeAll()
        logRuntime.signatureFailedIDs.removeAll()
        return
    }

    logRuntime.signatureLoadTask?.cancel()
    logRuntime.signatureGeneration += 1
    let generation = logRuntime.signatureGeneration
    let aggregate = isLogAggregate
    let grouped = Dictionary(grouping: commits) { $0.repositoryPath ?? "" }
    var requests: [LogSignatureBatchRequest] = []
    var unavailableKeys: Set<String> = []

    for (_, rootCommits) in grouped {
        let pending = rootCommits.filter { commit in
            let key = logCommitDisplayIdentity(
                repositoryPath: commit.repositoryPath,
                id: commit.id,
                aggregate: aggregate
            )
            return logRuntime.signatureStatuses[key] == nil
        }
        guard !pending.isEmpty else { continue }
        guard let repository = logRepository(for: pending) else {
            unavailableKeys.formUnion(pending.map { commit in
                logCommitDisplayIdentity(
                    repositoryPath: commit.repositoryPath,
                    id: commit.id,
                    aggregate: aggregate
                )
            })
            continue
        }
        requests.append(LogSignatureBatchRequest(
            repository: repository,
            commitIDs: pending.map(\.id),
            keyByCommitID: Dictionary(uniqueKeysWithValues: pending.map { commit in
                let key = logCommitDisplayIdentity(
                    repositoryPath: commit.repositoryPath,
                    id: commit.id,
                    aggregate: aggregate
                )
                return (commit.id, key)
            })
        ))
    }

    let requestedKeys = Set(requests.flatMap { $0.keyByCommitID.values })
    logRuntime.signatureLoadingIDs = requestedKeys
    logRuntime.signatureFailedIDs.formUnion(unavailableKeys)
    guard !requests.isEmpty else {
        return
    }
    logRuntime.signatureFailedIDs.subtract(requestedKeys)

    let requestBatch = requests
    let task = Task { @MainActor in
        let result = await Task.detached(priority: .userInitiated) {
            () -> LogSignatureLoadResult? in
            var statuses: [String: CommitSignatureInfo] = [:]
            var failedKeys: Set<String> = []
            for request in requestBatch {
                guard !Task.isCancelled else { return nil }
                do {
                    let loaded = try request.repository.commitSignatureStatuses(
                        commitIds: request.commitIDs
                    )
                    let loadedKeys = Set(loaded.compactMap {
                        request.keyByCommitID[$0.commitId]
                    })
                    for info in loaded {
                        if let key = request.keyByCommitID[info.commitId] {
                            statuses[key] = info
                        }
                    }
                    failedKeys.formUnion(
                        request.keyByCommitID.values.filter { !loadedKeys.contains($0) }
                    )
                } catch {
                    failedKeys.formUnion(request.keyByCommitID.values)
                }
            }
            return LogSignatureLoadResult(statuses: statuses, failedKeys: failedKeys)
        }.value

        guard !Task.isCancelled,
              generation == logRuntime.signatureGeneration,
              let result else { return }
        logRuntime.signatureStatuses.merge(result.statuses) { _, new in new }
        logRuntime.signatureLoadingIDs.subtract(requestedKeys)
        logRuntime.signatureFailedIDs.formUnion(result.failedKeys)
    }
    logRuntime.signatureLoadTask = task
}

}
