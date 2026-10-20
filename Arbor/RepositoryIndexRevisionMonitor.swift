import CoreServices
import SwiftUI


/// Keeps the staging workspace and Git metadata caches synchronized with Git
/// processes outside Arbor.
///
/// IntelliJ receives recursive VFS events for both the worktree and the real
/// Git administrative directory. The engine's index revision remains as a
/// fallback because Git commonly replaces `.git/index` through `index.lock`.
struct RepositoryIndexRevisionMonitor: View {
    let repo: Repository?
    let repositoryID: String?
    let rootPaths: [String]
    let onChanged: (RepositoryChangeEvent) -> Void

    init(
        repo: Repository?,
        repositoryID: String?,
        rootPaths: [String] = [],
        onChanged: @escaping (RepositoryChangeEvent) -> Void
    ) {
        self.repo = repo
        self.repositoryID = repositoryID
        self.rootPaths = rootPaths
        self.onChanged = onChanged
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: repositoryID) {
                await monitor()
            }
    }

    private func monitor() async {
        var repositories: [(repo: Repository, workdir: String)] = []
        let primaryPath = repo?.workdir().map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        for normalized in repositoryMonitorRootPaths(primary: primaryPath, additional: rootPaths) {
            if normalized == primaryPath, let repo {
                repositories.append((repo, normalized))
                continue
            }
            guard let rootRepo = try? openRepository(path: normalized),
                  let workdir = rootRepo.workdir() else { continue }
            repositories.append((rootRepo, URL(fileURLWithPath: workdir).standardizedFileURL.path))
        }
        guard !repositories.isEmpty else { return }

        let watchers = repositories.map { item in
            RepositoryFileChangeWatcher(
                workdir: item.workdir,
                gitDir: item.repo.gitDir(),
                excludedWorktreePaths: nestedRepositoryRootPaths(
                    rootPath: item.workdir,
                    allRootPaths: repositories.map(\.workdir)
                ),
                onChange: onChanged
            )
        }
        watchers.forEach { $0.start() }
        defer { watchers.forEach { $0.stop() } }

        // Keep the revision array in the same order as `repositories`; a
        // task-group's completion order is not stable and could otherwise
        // attribute one root's index change to another root.
        var previous: [IndexRevision?] = []
        for item in repositories {
            previous.append(await Self.readRevision(item.repo))
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            for index in repositories.indices {
                guard !Task.isCancelled else { return }
                guard let baseline = previous[index] else {
                    previous[index] = await Self.readRevision(repositories[index].repo)
                    continue
                }

                let changed = await Self.indexChanged(repositories[index].repo, since: baseline)
                guard changed else { continue }

                // Advance before notifying. This coalesces the write burst
                // from Git's index.lock -> index replacement with FSEvent
                // callbacks while keeping the event root-qualified.
                previous[index] = await Self.readRevision(repositories[index].repo) ?? baseline
                watchers[index].notify(scope: .gitMetadata)
            }
        }
    }

    private static func readRevision(_ repo: Repository) async -> IndexRevision? {
        await Task.detached(priority: .utility) {
            try? repo.indexRevision()
        }.value
    }

    private static func indexChanged(_ repo: Repository, since revision: IndexRevision) async -> Bool {
        await Task.detached(priority: .utility) {
            (try? repo.indexChangedSince(previous: revision)) ?? false
        }.value
    }
}
