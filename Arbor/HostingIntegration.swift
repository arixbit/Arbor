import Foundation
import AppKit

/// Aggregate Git operations return per-root result messages instead of
/// throwing. Keep the same authentication classification for those messages
/// as for single-root errors so their recovery UI is not silently skipped.
func arborAuthenticationFailureMessage(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("authentication failed")
        || normalized.contains("could not read username")
        || normalized.contains("permission denied (publickey)")
        || normalized.contains("publickey")
        || normalized.contains("http 401")
        || normalized.contains("status 401")
}

extension ContentView {
    func hostingRepositories(for remotes: [RemoteInfo]) -> [HostingRepository] {
        var seen = Set<String>()
        return remotes.compactMap { remote in
            guard let repository = HostingProvider.parse(remoteURL: remote.url) else {
                return nil
            }
            let key = "\(repository.provider.rawValue):\(repository.host.lowercased()):\(repository.projectPath)"
            guard seen.insert(key).inserted else { return nil }
            return repository
        }
    }

    func restoreRemoteProtectedBranchPatterns(for remotes: [RemoteInfo], projectPath: String?) {
        let patterns = hostingRepositories(for: remotes).isEmpty
            ? []
            : GitProtectedBranchRules.loadRemotePatterns(for: projectPath)
        remoteProtectedBranchPatterns = patterns
        if let projectPath {
            remoteProtectedBranchPatternsByRoot[canonicalExternalLogPath(projectPath)] = patterns
        }
    }

    /// Refreshes provider-backed branch protection after a successful fetch.
    /// The last known rules are intentionally kept when the API is unavailable:
    /// losing cached protection would make a later force push less safe.
    func synchronizeRemoteProtectedBranchPatterns(
        for rootPath: String? = nil,
        remotes suppliedRemotes: [RemoteInfo]? = nil
    ) {
        guard GitProtectedBranchRules.synchronizeRemotePatterns(for: projectPath),
              let projectPath else {
            if rootPath == nil {
                remoteProtectedBranchPatterns = []
            }
            return
        }

        let expectedProjectPath = projectPath
        let expectedRootPath = canonicalExternalLogPath(rootPath ?? projectPath)
        let rootRemotes = suppliedRemotes
            ?? multiRootBranchSnapshots.first(where: {
                canonicalExternalLogPath($0.rootPath) == expectedRootPath
            })?.remotes
            ?? remotes
        let repositories = hostingRepositories(for: rootRemotes)
        guard !repositories.isEmpty else {
            remoteProtectedBranchPatternsByRoot.removeValue(forKey: expectedRootPath)
            if expectedRootPath == canonicalExternalLogPath(expectedProjectPath) {
                remoteProtectedBranchPatterns = []
            }
            return
        }
        let cachedPatterns = remoteProtectedBranchPatternsByRoot[expectedRootPath]
            ?? GitProtectedBranchRules.loadRemotePatterns(for: expectedRootPath)
        Task {
            var patterns = Set<String>()
            var succeeded = false
            var failed = false
            for repository in repositories {
                do {
                    let masks = try await HostingClientFactory.make(for: repository)
                        .listProtectedBranchPatterns(for: repository)
                    patterns.formUnion(masks.map(GitProtectedBranchRules.githubMaskToRegex))
                    succeeded = true
                } catch {
                    failed = true
                    DiagnosticsLogger.shared.record(
                        level: .error,
                        operation: "protected-branches",
                        repositoryPath: expectedRootPath,
                        code: "sync-failed-\(repository.provider.rawValue)"
                    )
                }
            }
            guard succeeded else { return }
            // A partial provider failure must not discard the last known rules
            // for a provider that could not be queried this time.
            let synchronizedPatterns = GitProtectedBranchRules.synchronizedRemotePatterns(
                cachedPatterns: Array(cachedPatterns),
                fetchedPatterns: patterns,
                hasProviderFailure: failed
            )
            await MainActor.run {
                guard self.projectPath == expectedProjectPath else { return }
                self.remoteProtectedBranchPatternsByRoot[expectedRootPath] = synchronizedPatterns
                if expectedRootPath == canonicalExternalLogPath(expectedProjectPath) {
                    self.remoteProtectedBranchPatterns = synchronizedPatterns
                }
                GitProtectedBranchRules.saveRemotePatterns(synchronizedPatterns, for: expectedRootPath)
                DiagnosticsLogger.shared.record(
                    operation: "protected-branches",
                    repositoryPath: expectedRootPath,
                    code: failed ? "partial-sync" : "synchronized"
                )
            }
        }
    }

    func synchronizeRemoteProtectedBranchPatternsForAllRoots() {
        if multiRootBranchSnapshots.isEmpty {
            synchronizeRemoteProtectedBranchPatterns()
            return
        }
        for snapshot in multiRootBranchSnapshots {
            synchronizeRemoteProtectedBranchPatterns(
                for: snapshot.rootPath,
                remotes: snapshot.remotes
            )
        }
    }

    func openPullRequestsForCommit(_ commit: CommitInfo, remote: RemoteInfo) {
        guard let repository = HostingProvider.parse(remoteURL: remote.url) else {
            feedbackCenter.error(
                "Open pull requests unavailable",
                detail: "The selected remote is not a supported hosting provider.",
                nextStep: "Choose another hosted remote or configure a supported remote."
            )
            return
        }
        guard NSWorkspace.shared.open(repository.pullRequestsURL()) else {
            feedbackCenter.error(
                "Open pull requests failed",
                detail: repository.pullRequestsURL().absoluteString,
                nextStep: "Open the hosted repository manually."
            )
            return
        }
    }

    func beginReviewComment(_ commit: CommitInfo, remote: RemoteInfo) {
        guard let repository = HostingProvider.parse(remoteURL: remote.url) else {
            feedbackCenter.error(
                "Comment on commit unavailable",
                detail: "The selected remote is not a supported hosting provider.",
                nextStep: "Choose another hosted remote or configure a supported remote."
            )
            return
        }
        reviewCommentCommit = commit
        reviewCommentRepository = repository
        showReviewComment = true
    }

    func isAuthenticationFailure(_ error: Error) -> Bool {
        if let apiError = error as? GitHubAPIError {
            return apiError.isAuthenticationFailure
        }
        return arborAuthenticationFailureMessage(errorMessage(error))
    }
}
