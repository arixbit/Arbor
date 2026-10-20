import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
/// Reload the selected secondary root's complete Shelf state after an
/// external Git metadata change. The generation guard prevents an older VFS
/// event from replacing a newer root selection or a newer refresh result.
func reloadSecondaryShelfSnapshot(rootPath: String) {
    let normalizedRootPath = canonicalExternalLogPath(rootPath)
    guard activeShelfRootPath == normalizedRootPath,
          !shelfRootSelectionIsPrimary(
              selectedRootPath: normalizedRootPath,
              primaryRootPath: primaryShelfRootPath
          ) else { return }

    shelfWorkspace.rootLoadGeneration += 1
    let generation = shelfWorkspace.rootLoadGeneration
    shelfWorkspace.rootLoading = true
    Task.detached(priority: .utility) {
        do {
            let rootRepo = try openRepository(path: normalizedRootPath)
            let rootShelves = try rootRepo.shelveList()
            let rootDeletedShelves = (try? rootRepo.shelveDeletedList()) ?? []
            let rootChangeLists = (try? rootRepo.changelistList()) ?? []
            await MainActor.run {
                guard self.shelfWorkspace.rootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedRootPath else { return }
                self.shelfWorkspace.rootRepository = rootRepo
                self.shelfWorkspace.rootSnapshots[normalizedRootPath] = ShelfRootSnapshot(
                    rootPath: normalizedRootPath,
                    shelves: rootShelves,
                    deletedShelves: rootDeletedShelves,
                    changeLists: rootChangeLists
                )
                self.shelfWorkspace.rootError = nil
                self.shelfWorkspace.rootLoading = false
            }
        } catch {
            await MainActor.run {
                guard self.shelfWorkspace.rootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedRootPath else { return }
                self.shelfWorkspace.rootError = "Refresh Shelf for "
                    + normalizedRootPath
                    + " failed: "
                    + errorMessage(error)
                self.shelfWorkspace.rootLoading = false
            }
        }
    }
}

func publishShelfSnapshot(
    rootPath: String,
    shelves: [ShelveInfo],
    deletedShelves: [ShelveInfo],
    changeLists: [ChangeListInfo]? = nil
) {
    let normalizedRootPath = canonicalExternalLogPath(rootPath)
    if shelfRootSelectionIsPrimary(
        selectedRootPath: normalizedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) {
        self.shelfWorkspace.shelves = shelves
        self.shelfWorkspace.deletedShelves = deletedShelves
        if let changeLists {
            self.repositoryStatus.changeLists = changeLists
        }
    } else if activeShelfRootPath == normalizedRootPath {
        let previousChangeLists = shelfWorkspace.rootSnapshots[normalizedRootPath]?.changeLists ?? []
        shelfWorkspace.rootSnapshots[normalizedRootPath] = ShelfRootSnapshot(
            rootPath: normalizedRootPath,
            shelves: shelves,
            deletedShelves: deletedShelves,
            changeLists: changeLists ?? previousChangeLists
        )
    }
}

/// Select the repository whose Shelves are shown in the Commit workspace.
/// Secondary roots keep their own snapshot and repository so metadata-only
/// Shelf mutations cannot accidentally target the primary repository.
func setShelfRoot(_ rootPath: String) {
    let normalizedPath = canonicalExternalLogPath(rootPath)
    let primaryPath = primaryShelfRootPath
    guard availableShelfRoots.contains(where: {
        canonicalExternalLogPath($0.path) == normalizedPath
    }) else {
        return
    }

    shelfWorkspace.rootLoadGeneration += 1
    let generation = shelfWorkspace.rootLoadGeneration
    shelfWorkspace.rootError = nil
    shelfWorkspace.previewName = nil
    shelfWorkspace.previewRootPath = nil
    shelfWorkspace.previewText = nil
    shelfWorkspace.previewIsDeleted = false
    shelfWorkspace.showPreview = false

    if normalizedPath == primaryPath {
        shelfWorkspace.rootPath = nil
        shelfWorkspace.rootRepository = nil
        shelfWorkspace.rootLoading = false
        return
    }

    shelfWorkspace.rootPath = normalizedPath
    shelfWorkspace.rootRepository = nil
    shelfWorkspace.rootLoading = true
    if shelfWorkspace.rootSnapshots[normalizedPath] == nil,
       let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
           canonicalExternalLogPath($0.rootPath) == normalizedPath
       }) {
        shelfWorkspace.rootSnapshots[normalizedPath] = ShelfRootSnapshot(
            rootPath: normalizedPath,
            shelves: snapshot.shelves,
            deletedShelves: [],
            changeLists: []
        )
    }

    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: normalizedPath)
            let rootShelves = try rootRepo.shelveList()
            let rootDeletedShelves = (try? rootRepo.shelveDeletedList()) ?? []
            let rootChangeLists = (try? rootRepo.changelistList()) ?? []
            await MainActor.run {
                guard self.shelfWorkspace.rootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedPath else { return }
                self.shelfWorkspace.rootRepository = rootRepo
                self.shelfWorkspace.rootSnapshots[normalizedPath] = ShelfRootSnapshot(
                    rootPath: normalizedPath,
                    shelves: rootShelves,
                    deletedShelves: rootDeletedShelves,
                    changeLists: rootChangeLists
                )
                self.shelfWorkspace.rootLoading = false
            }
        } catch {
            await MainActor.run {
                guard self.shelfWorkspace.rootLoadGeneration == generation,
                      self.activeShelfRootPath == normalizedPath else { return }
                self.shelfWorkspace.rootRepository = nil
                self.shelfWorkspace.rootLoading = false
                self.shelfWorkspace.rootError = "Load Shelf for "
                    + normalizedPath
                    + " failed: "
                    + errorMessage(error)
            }
        }
    }
}

/// Load the active repository's Shelf location before presenting the settings
/// sheet. The location is repository-scoped, so a secondary Git root must be
/// resolved through the same context used by every other Shelf mutation.
func presentShelfLocationSettings() {
    guard let rootPath = activeShelfRootPath,
          let shelfRepo = activeShelfRepository,
          canMutateShelfMetadata else { return }
    do {
        let location = try shelfRepo.shelveLocation()
        shelfWorkspace.locationCurrent = location
        shelfWorkspace.locationValue = location
        shelfWorkspace.locationMigrateExisting = true
        shelfWorkspace.showLocationDialog = true
    } catch {
        feedbackCenter.error(
            "Load Shelf location failed",
            detail: errorMessage(error),
            notificationID: shelfMetadataNotificationID(operation: "location", rootPath: rootPath)
        )
    }
}

/// Switch the active repository to a custom Shelf directory. The Rust engine
/// performs copy-then-marker migration and leaves Git refs in place; this
/// method only refreshes the root snapshot after that transaction succeeds.
func setShelfLocation(
    _ location: String,
    migrateExisting: Bool,
    rootPath: String?
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfWorkspace.rootRepository
    ) else { return }
    let shelfRepo = context.repository
    let resolvedRootPath = context.rootPath
    let requested = location.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requested.isEmpty else { return }
    beginFeedbackOperation("Change Shelf location")
    Task.detached(priority: .userInitiated) {
        do {
            let resolved = try shelfRepo.shelveSetLocation(
                location: requested,
                migrateExisting: migrateExisting
            )
            let nextShelves = try shelfRepo.shelveList()
            let nextDeletedShelves = (try? shelfRepo.shelveDeletedList()) ?? []
            let nextChangeLists = (try? shelfRepo.changelistList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.shelfWorkspace.locationCurrent = resolved
                self.shelfWorkspace.locationValue = resolved
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: nextShelves,
                    deletedShelves: nextDeletedShelves,
                    changeLists: nextChangeLists
                )
                self.feedbackCenter.success(
                    "Shelf location changed",
                    detail: resolved,
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "location",
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Change Shelf location failed",
                    detail: errorMessage(error),
                    nextStep: "Choose an empty directory or retry the migration after checking its permissions.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "location",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// Reconcile a Shelf/Apply Patch mutation through the same root-scoped dirty
/// lifecycle as an external VFS event. Updating `entries` directly is not
/// enough: file previews, the staging model, and the index revision cache
/// must all observe the post-apply worktree/index boundary.
func refreshAfterShelfMutation(
    repo: Repository,
    paths: [String],
    metadataChanged: Bool = true
) {
    guard let workdir = repo.workdir() else {
        refreshAll(showFeedback: false)
        return
    }

    let dirtyPaths = repositoryShelfMutationDirtyPaths(
        workdir: workdir,
        paths: paths
    )
    let scope = dirtyPaths.isEmpty
        ? RepositoryDirtyScope(
            files: [],
            directories: [],
            nonRecursiveDirectories: [],
            everything: !metadataChanged
        )
        : repositoryDirtyScope(
            workdir: workdir,
            gitDir: repo.gitDir(),
            dirtyPaths: dirtyPaths
        )
    let changeScope: RepositoryChangeScope = metadataChanged
        ? [.worktree, .gitMetadata]
        : [.worktree]

    // Keep the exact path ledger in lockstep with the compacted scope. Shelf
    // operations are internal writes, so they do not enter the external VCS
    // action queue, but their file events still need the same acknowledge
    // boundary as watcher-delivered changes.
    repositoryStatus.dirtyFileManager.mark(
        repositoryPath: workdir,
        dirtyPaths: dirtyPaths
    )
    _ = repositoryStatus.dirtyScopeManager.mark(
        repositoryPath: workdir,
        scope: scope,
        changeScope: changeScope,
        dirtyPaths: dirtyPaths
    )
    startPendingRepositoryDirtyScopes()
}

}
