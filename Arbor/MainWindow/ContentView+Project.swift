import SwiftUI
import AppKit

extension ContentView {
    var repo: Repository? {
        projectWorkspace.repository
    }

    var searchEverywhereGitRoots: [SearchEverywhereGitRoot] {
        if !multiRootWorkspace.branchSnapshots.isEmpty {
            return multiRootWorkspace.branchSnapshots.map { snapshot in
                SearchEverywhereGitRoot(
                    rootPath: snapshot.rootPath,
                    displayName: snapshot.displayName,
                    relativePath: snapshot.relativePath,
                    branches: snapshot.branches,
                    remoteBranches: snapshot.remoteBranches,
                    tags: snapshot.tags
                )
            }
        }
        guard let repositoryPath = repo?.workdir(), !repositoryPath.isEmpty else {
            return []
        }
        let displayName = URL(fileURLWithPath: repositoryPath).lastPathComponent
        return [SearchEverywhereGitRoot(
            rootPath: repositoryPath,
            displayName: displayName.isEmpty ? repositoryPath : displayName,
            relativePath: ".",
            branches: branchWorkspace.branches,
            remoteBranches: branchWorkspace.remoteBranches,
            tags: tagWorkspace.tags
        )]
    }

    var newWorktreeRepository: Repository? {
        guard let rootPath = worktreeWorkspace.rootPath, !rootPath.isEmpty else {
            return repo
        }
        return try? openRepository(path: rootPath)
    }

    var newWorktreeBranches: [BranchInfo] {
        guard let rootPath = worktreeWorkspace.rootPath,
              let snapshot = multiRootWorkspace.branchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return branchWorkspace.branches
        }
        return snapshot.branches
    }

    var newWorktreeWorktrees: [WorktreeInfo] {
        guard let rootPath = worktreeWorkspace.rootPath,
              let snapshot = multiRootWorkspace.branchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return worktreeWorkspace.worktrees
        }
        return snapshot.worktrees
    }

    // Kept internal so the AppKit/WindowGroup lifecycle recovery can repeat
    // the same valid-repository selection after state restoration.
    static func recentProjectPath() -> String? {
        let paths = UserDefaults.standard.stringArray(forKey: "lastOpenedPaths") ?? []
        let gitDirectories = paths.filter { candidate in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            // A recent folder is not automatically a Git project. Rebased
            // restores the last usable VCS workspace; reopening an arbitrary
            // source folder here would send the user back to the empty-state
            // shell with no log, branches, or Commit workspace data.
            var isGitMarkerDirectory: ObjCBool = false
            let gitMarker = URL(fileURLWithPath: candidate)
                .appendingPathComponent(".git")
                .path
            return FileManager.default.fileExists(
                atPath: gitMarker,
                isDirectory: &isGitMarkerDirectory
            )
        }

        return gitDirectories.first
    }

    var hostingRepositories: [HostingRepository] {
        hostingRepositories(for: remoteWorkspace.remotes)
    }

    var hostingRepository: HostingRepository? {
        hostingRepositories.first
    }

    var resetHeadRootOptions: [GitRootInfo] {
        if !multiRootWorkspace.roots.isEmpty {
            return multiRootWorkspace.roots.filter { $0.operation == nil }
        }
        guard let rootPath = repo?.workdir(), !rootPath.isEmpty else { return [] }
        return [GitRootInfo(
            path: rootPath,
            displayName: URL(fileURLWithPath: rootPath).lastPathComponent,
            relativePath: ".",
            isSubmodule: false,
            headBranch: branchWorkspace.branches.first(where: { $0.isCurrent })?.name,
            headId: nil,
            dirty: repositoryStatus.entries.contains {
                $0.staged != .unchanged || $0.unstaged != .unchanged
            },
            operation: operationRecovery.operation?.kind
        )]
    }

    var stashRootOptions: [GitRootInfo] {
        if !multiRootWorkspace.roots.isEmpty {
            return multiRootWorkspace.roots
        }
        return resetHeadRootOptions
    }

    /// The top-level Unstash dialog must switch to the root-qualified
    /// operations once the project has more than one discovered repository.
    /// A single-root window keeps the existing stash conflict surface.
    var useRootScopedUnstashActions: Bool {
        multiRootWorkspace.roots.count > 1
    }
}
