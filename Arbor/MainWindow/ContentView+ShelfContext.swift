import SwiftUI
import AppKit

extension ContentView {

    var primaryShelfRootPath: String? {
        if let workdir = repo?.workdir(), !workdir.isEmpty {
            return canonicalExternalLogPath(workdir)
        }
        if let projectPath = projectWorkspace.path, !projectPath.isEmpty {
            return canonicalExternalLogPath(projectPath)
        }
        return nil
    }

    var availableShelfRoots: [GitRootInfo] {
        guard multiRootWorkspace.roots.count > 1 else { return [] }
        let primary = primaryShelfRootPath
        return multiRootWorkspace.roots.sorted { lhs, rhs in
            let lhsIsPrimary = canonicalExternalLogPath(lhs.path) == primary
            let rhsIsPrimary = canonicalExternalLogPath(rhs.path) == primary
            if lhsIsPrimary != rhsIsPrimary { return lhsIsPrimary }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    var activeShelfRootPath: String? {
        if let rootPath = shelfWorkspace.rootPath, !rootPath.isEmpty {
            return canonicalExternalLogPath(rootPath)
        }
        return primaryShelfRootPath
    }

    var isShelfRootReadOnly: Bool {
        !shelfRootSelectionIsPrimary(
            selectedRootPath: shelfWorkspace.rootPath,
            primaryRootPath: primaryShelfRootPath
        )
    }

    var canApplyShelfWorktree: Bool {
        !shelfWorkspace.rootLoading
            && shelfWorkspace.rootError == nil
            && activeShelfRootPath != nil
            && activeShelfRepository != nil
    }

    var canMutateShelfMetadata: Bool {
        canApplyShelfWorktree
    }

    var activeShelfSnapshot: ShelfRootSnapshot? {
        guard let rootPath = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: rootPath,
                  primaryRootPath: primaryShelfRootPath
              ) else { return nil }
        return shelfWorkspace.rootSnapshots[rootPath]
            ?? multiRootWorkspace.branchSnapshots.first(where: {
                canonicalExternalLogPath($0.rootPath) == rootPath
            }).map {
                ShelfRootSnapshot(
                    rootPath: rootPath,
                    shelves: $0.shelves,
                    deletedShelves: []
                )
            }
    }

    var activeShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return shelfWorkspace.shelves }
        return activeShelfSnapshot?.shelves ?? []
    }

    var activeShelfChangeLists: [ChangeListInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return repositoryStatus.changeLists }
        return activeShelfSnapshot?.changeLists ?? []
    }

    var activeDeletedShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return shelfWorkspace.deletedShelves }
        return activeShelfSnapshot?.deletedShelves ?? []
    }

    var activeShelfRepository: Repository? {
        guard let rootPath = activeShelfRootPath else { return repo }
        if shelfRootSelectionIsPrimary(
            selectedRootPath: rootPath,
            primaryRootPath: primaryShelfRootPath
        ) { return repo }
        return shelfWorkspace.rootRepository
    }
}
