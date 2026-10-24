import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
/// Shelf 工作区的内嵌预览入口。Shelf 名称稳定，不使用会因 drop/pop 重排的数字索引。
func showShelvePreviewFor(_ name: String) {
    guard let rootPath = activeShelfRootPath,
          let shelfRepo = activeShelfRepository else { return }
    let activeShelves = activeShelfList
    let activeDeletedShelves = activeDeletedShelfList
    let isDeleted = !activeShelves.contains(where: { $0.name == name })
        && activeDeletedShelves.contains(where: { $0.name == name })
    guard activeShelves.contains(where: { $0.name == name }) || isDeleted else { return }
    stashUI.previewStashID = nil
    stashUI.previewText = nil
    stashUI.showPreview = false
    shelfWorkspace.previewName = name
    shelfWorkspace.previewRootPath = rootPath
    shelfWorkspace.previewIsDeleted = isDeleted
    shelfWorkspace.previewText = nil
    shelfWorkspace.showPreview = true
    Task.detached(priority: .userInitiated) {
        do {
            let diff = try isDeleted
                ? shelfRepo.shelveDeletedDiff(name: name)
                : shelfRepo.shelveDiff(name: name)
            await MainActor.run {
                guard self.shelfWorkspace.showPreview,
                      shelfPreviewRequestMatches(
                          requestedRootPath: rootPath,
                          currentRootPath: self.shelfWorkspace.previewRootPath,
                          requestedName: name,
                          currentName: self.shelfWorkspace.previewName,
                          requestedIsDeleted: isDeleted,
                          currentIsDeleted: self.shelfWorkspace.previewIsDeleted
                      ) else { return }
                self.shelfWorkspace.previewText = diff
            }
        } catch {
            await MainActor.run {
                guard self.shelfWorkspace.showPreview,
                      shelfPreviewRequestMatches(
                          requestedRootPath: rootPath,
                          currentRootPath: self.shelfWorkspace.previewRootPath,
                          requestedName: name,
                          currentName: self.shelfWorkspace.previewName,
                          requestedIsDeleted: isDeleted,
                          currentIsDeleted: self.shelfWorkspace.previewIsDeleted
                      ) else { return }
                self.shelfWorkspace.previewText = "Load shelf diff failed: \(errorMessage(error))"
            }
        }
    }
}

/// IntelliJ's Shelf tree accepts a drag from the Changes tree and silently
/// creates one ShelvedChangeList per source Changelist. Keep that grouping when
/// several local lists are selected; the engine still owns each shelf
/// transaction and the worktree reset.
func shelveDraggedPaths(_ paths: [String]) {
    guard let repo, !paths.isEmpty else { return }
    let selected = Set(paths)
    let suffix = String(UUID().uuidString.prefix(8))
    let sourceLists = repositoryStatus.changeLists.isEmpty
        ? [("Default", paths)]
        : repositoryStatus.changeLists.compactMap { list -> (String, [String])? in
            let members = list.paths.filter { selected.contains($0) }
            return members.isEmpty ? nil : (list.name, members)
        }
    let groupedPaths = sourceLists.isEmpty ? [("Default", paths)] : sourceLists
    beginFeedbackOperation("Shelve dragged changes")
    Task.detached(priority: .userInitiated) {
        var createdNames: [String] = []
        do {
            for (listName, listPaths) in groupedPaths {
                let name = "\(listName) — \(suffix)"
                try repo.shelve(name: name, paths: listPaths)
                createdNames.append(name)
            }
            let status = try repo.status()
            let nextChangeLists = (try? repo.changelistList()) ?? []
            let nextShelves = try repo.shelveList()
            let nextDeletedShelves = (try? repo.shelveDeletedList()) ?? []
            let createdDetail = createdNames.joined(separator: ", ")
            await MainActor.run {
                self.repositoryStatus.entries = status
                self.repositoryStatus.changeLists = nextChangeLists
                self.shelfWorkspace.shelves = nextShelves
                self.shelfWorkspace.deletedShelves = nextDeletedShelves
                self.refreshAfterShelfMutation(repo: repo, paths: paths)
                self.feedbackCenter.success("Changes shelved", detail: createdDetail)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Shelve dragged changes failed",
                    detail: errorMessage(error),
                    nextStep: "Select tracked or untracked changes in the Changes tree and try again."
                )
            }
        }
    }
}

/// Import one or more portable unified/binary patches into the active Shelf.
/// The panel is intentionally kept as a small AppKit boundary; the engine
/// owns patch validation and isolated-index construction.
func importShelvePatches(rootPath: String? = nil) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfWorkspace.rootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.prompt = "Import Patches"
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    let urls = panel.urls
    beginFeedbackOperation("Import patches into shelf")
    Task.detached(priority: .userInitiated) {
        var imported = 0
        var failures: [String] = []
        for url in urls {
            do {
                let patch = try String(contentsOf: url, encoding: .utf8)
                let baseName = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = baseName.isEmpty ? "Imported Patch" : baseName
                try shelfRepository.shelveImport(name: name, patch: patch)
                imported += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(errorMessage(error))")
            }
        }
        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let importedCount = imported
        let failureDetails = failures
        await MainActor.run {
            guard shelfActionRootMatchesCurrentRoot(
                requestedRootPath: resolvedRootPath,
                currentRootPath: self.activeShelfRootPath
            ) else { return }
            self.publishShelfSnapshot(
                rootPath: resolvedRootPath,
                shelves: nextShelves,
                deletedShelves: nextDeletedShelves
            )
            if importedCount > 0 && failureDetails.isEmpty {
                self.feedbackCenter.success(
                    "Patches imported",
                    detail: "\(importedCount) shelf(s)",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "import",
                        rootPath: resolvedRootPath
                    )
                )
            } else if importedCount > 0 {
                self.feedbackCenter.warning(
                    "Some patches imported",
                    detail: failureDetails.joined(separator: "\n"),
                    nextStep: "Fix the failed patch names or base revisions, then import again.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "import",
                        rootPath: resolvedRootPath
                    )
                )
            } else {
                self.feedbackCenter.error(
                    "Patch import failed",
                    detail: failureDetails.isEmpty ? "No patches were imported." : failureDetails.joined(separator: "\n"),
                    nextStep: "Choose a valid unified or binary patch based on the current HEAD.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "import",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// Export a shelf as a portable Git patch. The engine emits binary metadata and
/// disables external diff/textconv, matching the existing preview safety rule.
func exportShelve(_ name: String, rootPath: String? = nil) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfWorkspace.rootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    guard (try? shelfRepository.shelveList().contains(where: { $0.name == name })) == true else {
        return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(name.replacingOccurrences(of: " ", with: "_")).patch"
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    panel.prompt = "Export Patch"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    beginFeedbackOperation("Export shelf patch")
    Task.detached(priority: .userInitiated) {
        do {
            let patch = try shelfRepository.shelveDiff(name: name)
            try patch.write(to: destination, atomically: true, encoding: .utf8)
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.feedbackCenter.success(
                    "Patch exported",
                    detail: destination.lastPathComponent,
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "export",
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.feedbackCenter.error(
                    "Patch export failed",
                    detail: errorMessage(error),
                    nextStep: "Choose a writable destination and retry.",
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "export",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// shelve 当前激活仓库的全部变更。
func doShelve(
    paths selectedPaths: [String]? = nil,
    includeUntracked: Bool = false,
    includeIgnored: Bool = false
) {
    guard let repo, !shelfWorkspace.name.isEmpty else { return }
    let name = shelfWorkspace.name
    let paths = selectedPaths ?? repositoryStatus.entries.compactMap { entry in
        if entry.unstaged == .ignored && !includeIgnored { return nil }
        if entry.unstaged == .untracked && !includeUntracked { return nil }
        return entry.path
    }
    guard !paths.isEmpty else { return }
    beginFeedbackOperation("Shelve changes")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.shelveWithOptions(
                name: name,
                paths: paths,
                includeUntracked: includeUntracked,
                includeIgnored: includeIgnored
            )
            let st = try repo.status()
            let cls = (try? repo.changelistList()) ?? []
            let ss = try repo.shelveList()
            let dsh = (try? repo.shelveDeletedList()) ?? []
            await MainActor.run {
                self.repositoryStatus.entries = st; self.repositoryStatus.changeLists = cls; self.shelfWorkspace.shelves = ss; self.shelfWorkspace.deletedShelves = dsh; self.shelfWorkspace.name = ""
                self.refreshAfterShelfMutation(repo: repo, paths: paths)
                self.feedbackCenter.success("Changes shelved")
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
}

func renameShelve(
    _ name: String,
    currentDescription: String,
    rootPath: String? = nil
) {
    let alert = NSAlert()
    alert.messageText = String(localized: "Rename Shelf")
    alert.informativeText = name
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = currentDescription
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let newDescription = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newDescription.isEmpty, newDescription != currentDescription else { return }
    renameShelveDescription(name, newDescription, rootPath: rootPath)
}

func renameShelveDescription(
    _ name: String,
    _ description: String,
    rootPath: String? = nil
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfWorkspace.rootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    beginFeedbackOperation("Rename shelf")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveSetDescription(name: name, description: description)
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh
                )
                self.feedbackCenter.success(
                    "Shelf renamed",
                    detail: name,
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "rename",
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Shelf rename failed",
                    detail: errorMessage(error),
                    notificationID: self.shelfMetadataNotificationID(
                        operation: "rename",
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

}
