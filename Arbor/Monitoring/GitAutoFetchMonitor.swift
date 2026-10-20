import CoreServices
import SwiftUI


/// Serializes automatic fetches for the same Git root when a project is open
/// in more than one window. Manual Git operations remain user-controlled; the
/// gate only prevents two background fetch loops from racing each other.
private actor GitAutoFetchCoordinator {
    static let shared = GitAutoFetchCoordinator()

    private var activeRoots: Set<String> = []

    func acquire(rootID: String) -> Bool {
        guard activeRoots.insert(rootID).inserted else { return false }
        return true
    }

    func release(rootID: String) {
        activeRoots.remove(rootID)
    }
}

enum GitIncomingCheckSchedule {
    /// Equivalent to IntelliJ's `git.update.incoming.info.time` registry key.
    /// Keep this internal: IntelliJ exposes the value through Registry rather
    /// than the project Git settings UI.
    static let intervalMinutesKey = "arbor.git.incomingCheckIntervalMinutes.v1"
    static let defaultIntervalMinutes: UInt64 = 20

    static func intervalMinutes(defaults: UserDefaults = .standard) -> UInt64 {
        let configured = defaults.integer(forKey: intervalMinutesKey)
        guard configured > 0 else { return defaultIntervalMinutes }
        return UInt64(configured)
    }

    static func intervalSeconds(defaults: UserDefaults = .standard) -> UInt64 {
        intervalMinutes(defaults: defaults) * 60
    }
}

func autoFetchDelaySeconds(
    firstRun: Bool,
    defaults: UserDefaults = .standard
) -> UInt64? {
    // GitBranchIncomingOutgoingManager performs the first remote check when
    // the project is activated, then schedules the next check using the
    // Registry-configured minute interval. A retry starts a new task
    // generation, so it receives the same immediate first pass without a
    // separate one-shot boolean.
    firstRun ? nil : GitIncomingCheckSchedule.intervalSeconds(defaults: defaults)
}

func autoFetchRootFailure(rootPath: String, stage: String, error: Error) -> String {
    "\(rootPath) · \(stage): \(error.localizedDescription)"
}

func autoFetchNotificationFingerprint(_ values: [String]) -> String {
    groupedAutoFetchValues(values).joined(separator: "\n")
}

struct GitAutoFetchMonitor: View {
    let rootPaths: [String]
    let repositoryID: String
    let broker: CredentialBroker
    let strategy: GitIncomingCheckStrategy
    let tagMode: FetchTagsMode
    let onUpdated: ([String]) -> Void
    let onUnfetched: (GitIncomingBranchesSnapshot) -> Void
    let onFailure: ([String]) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: "\(repositoryID)|\(strategy.rawValue)|\(tagMode)") {
                await monitor()
            }
    }

    private func monitor() async {
        guard strategy != .none else { return }

        var firstRun = true
        // IntelliJ's incoming/outgoing manager starts each remote in
        // AuthenticationMode.NONE and promotes it to SILENT only after a
        // successful check. Keep this process-local set so a public remote
        // does not repeatedly take the no-auth path, while an explicit
        // interactive fetch can seed the same state through the broker.
        var silentRemotes: Set<String> = []
        while !Task.isCancelled {
            if let delay = autoFetchDelaySeconds(firstRun: firstRun) {
                do {
                    // Match the reference incoming-change service: the first
                    // check is immediate, subsequent checks use its cadence.
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            firstRun = false
            guard !Task.isCancelled else { return }

            var updatedRefs: [String] = []
            var unfetchedBranches: [GitIncomingBranch] = []
            var configuredRoots: Set<String> = []
            var configuredRemotes: Set<GitIncomingRemote> = []
            var checkedRemotes: Set<GitIncomingRemote> = []
            var failures: [String] = []
            let paths = mergedAutoFetchRootPaths(primary: nil, discovered: rootPaths)

            for rootPath in paths {
                guard !Task.isCancelled else { break }
                let repo: Repository
                do {
                    repo = try openRepository(path: rootPath)
                } catch {
                    failures.append(
                        autoFetchRootFailure(
                            rootPath: rootPath,
                            stage: "Open Git repository",
                            error: error
                        )
                    )
                    continue
                }

                let remotes: [RemoteInfo]
                do {
                    remotes = try repo.remoteList()
                } catch {
                    failures.append(
                        autoFetchRootFailure(
                            rootPath: rootPath,
                            stage: "Load Git remotes",
                            error: error
                        )
                    )
                    continue
                }
                configuredRoots.insert(normalizedGitRootPath(rootPath))
                configuredRemotes.formUnion(remotes.map {
                    GitIncomingRemote(rootPath: rootPath, remote: $0.name)
                })
                guard !remotes.isEmpty else {
                    continue
                }

                let rootID = repo.gitDir()
                guard await GitAutoFetchCoordinator.shared.acquire(rootID: rootID) else {
                    continue
                }

                var rootUpdatedRefs: [String] = []
                var rootUnfetchedBranches: [GitIncomingBranch] = []
                var rootFailures: [String] = []
                for remote in remotes {
                    guard !Task.isCancelled else { break }
                    let cancel = GitCancelHandle()
                    let remoteKey = "\(normalizedGitRootPath(rootPath))|\(remote.name)"
                    let useSilentAuth = silentRemotes.contains(remoteKey)
                        || broker.hasSuccessfulAuthentication(remoteUrl: remote.url)
                    let operation = Task.detached(priority: .utility) {
                        switch strategy {
                        case .none:
                            return (updated: [String](), unfetched: [String]())
                        case .fetch:
                            let outcome: FetchOutcome = if useSilentAuth {
                                try repo.fetchWithOptionsAndSilentAuthAndCancel(
                                    remote: remote.name,
                                    tagMode: tagMode,
                                    broker: broker,
                                    cancel: cancel
                                )
                            } else {
                                try repo.fetchWithOptionsWithoutAuthAndCancel(
                                    remote: remote.name,
                                    tagMode: tagMode,
                                    cancel: cancel
                                )
                            }
                            return (updated: outcome.updated, unfetched: [String]())
                        case .lsRemote:
                            let branches: [String] = if useSilentAuth {
                                try repo.remoteIncomingBranchesWithSilentAuthAndCancel(
                                    remote: remote.name,
                                    broker: broker,
                                    cancel: cancel
                                )
                            } else {
                                try repo.remoteIncomingBranchesWithoutAuthAndCancel(
                                    remote: remote.name,
                                    cancel: cancel
                                )
                            }
                            return (updated: [String](), unfetched: branches)
                        }
                    }

                    do {
                        let outcome = try await withTaskCancellationHandler(operation: {
                            try await operation.value
                        }, onCancel: {
                            cancel.cancel()
                        })
                        silentRemotes.insert(remoteKey)
                        rootUpdatedRefs.append(contentsOf: outcome.updated.map {
                            "\(remote.name)/\($0)"
                        })
                        checkedRemotes.insert(GitIncomingRemote(rootPath: rootPath, remote: remote.name))
                        rootUnfetchedBranches.append(contentsOf: outcome.unfetched.map {
                            GitIncomingBranch(
                                rootPath: rootPath,
                                remote: remote.name,
                                branch: $0
                            )
                        })
                    } catch is CancellationError {
                        cancel.cancel()
                        operation.cancel()
                        break
                    } catch {
                        rootFailures.append("\(rootPath) · \(remote.name): \(error.localizedDescription)")
                    }
                }

                await GitAutoFetchCoordinator.shared.release(rootID: rootID)
                updatedRefs.append(contentsOf: rootUpdatedRefs)
                unfetchedBranches.append(contentsOf: rootUnfetchedBranches)
                failures.append(contentsOf: rootFailures)
            }

            guard !Task.isCancelled else { return }
            let groupedUpdatedRefs = groupedAutoFetchValues(updatedRefs)
            let incomingSnapshot = GitIncomingBranchesSnapshot(
                branches: unfetchedBranches,
                configuredRoots: configuredRoots,
                configuredRemotes: configuredRemotes,
                checkedRemotes: checkedRemotes
            )
            let groupedFailures = groupedAutoFetchValues(failures)
            if !groupedUpdatedRefs.isEmpty {
                await MainActor.run {
                    onUpdated(groupedUpdatedRefs)
                }
            }
            await MainActor.run {
                // Publish the complete snapshot, including an empty one, so
                // a later clean check clears IntelliJ-style stale incoming
                // state and its notification.
                onUnfetched(incomingSnapshot)
            }
            await MainActor.run {
                // Failures are also a cycle snapshot. An empty result clears
                // an error from a previous cycle after recovery.
                onFailure(groupedFailures)
            }
        }
    }
}
