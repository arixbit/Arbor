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
    shelfPreviewName = name
    shelfPreviewRootPath = rootPath
    shelfPreviewIsDeleted = isDeleted
    shelfPreviewText = nil
    showShelfPreview = true
    Task.detached(priority: .userInitiated) {
        do {
            let diff = try isDeleted
                ? shelfRepo.shelveDeletedDiff(name: name)
                : shelfRepo.shelveDiff(name: name)
            await MainActor.run {
                guard self.showShelfPreview,
                      shelfPreviewRequestMatches(
                          requestedRootPath: rootPath,
                          currentRootPath: self.shelfPreviewRootPath,
                          requestedName: name,
                          currentName: self.shelfPreviewName,
                          requestedIsDeleted: isDeleted,
                          currentIsDeleted: self.shelfPreviewIsDeleted
                      ) else { return }
                self.shelfPreviewText = diff
            }
        } catch {
            await MainActor.run {
                guard self.showShelfPreview,
                      shelfPreviewRequestMatches(
                          requestedRootPath: rootPath,
                          currentRootPath: self.shelfPreviewRootPath,
                          requestedName: name,
                          currentName: self.shelfPreviewName,
                          requestedIsDeleted: isDeleted,
                          currentIsDeleted: self.shelfPreviewIsDeleted
                      ) else { return }
                self.shelfPreviewText = "Load shelf diff failed: \(errorMessage(error))"
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
    let sourceLists = changeLists.isEmpty
        ? [("Default", paths)]
        : changeLists.compactMap { list -> (String, [String])? in
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
                self.entries = status
                self.changeLists = nextChangeLists
                self.shelves = nextShelves
                self.deletedShelves = nextDeletedShelves
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
        secondaryRepository: shelfRootRepository
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
        secondaryRepository: shelfRootRepository
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

func loadShelves() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let ss = try repo.shelveList()
            let dsh = (try? repo.shelveDeletedList()) ?? []
            await MainActor.run {
                self.shelves = ss
                self.deletedShelves = dsh
                if let name = self.shelfPreviewName,
                   !ss.contains(where: { $0.name == name }),
                   !dsh.contains(where: { $0.name == name }) {
                    self.shelfPreviewName = nil
                    self.shelfPreviewIsDeleted = false
                    self.shelfPreviewText = nil
                    self.showShelfPreview = false
                }
            }
        } catch { await MainActor.run { self.loadError = errorMessage(error) } }
    }
}

/// shelve 当前激活仓库的全部变更。
func doShelve(
    paths selectedPaths: [String]? = nil,
    includeUntracked: Bool = false,
    includeIgnored: Bool = false
) {
    guard let repo, !shelveName.isEmpty else { return }
    let name = shelveName
    let paths = selectedPaths ?? entries.compactMap { entry in
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
                self.entries = st; self.changeLists = cls; self.shelves = ss; self.deletedShelves = dsh; self.shelveName = ""
                self.refreshAfterShelfMutation(repo: repo, paths: paths)
                self.feedbackCenter.success("Changes shelved")
            }
        } catch { await MainActor.run { self.loadError = errorMessage(error) } }
    }
}

func renameShelve(
    _ name: String,
    currentDescription: String,
    rootPath: String? = nil
) {
    let alert = NSAlert()
    alert.messageText = "Rename Shelf"
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
        secondaryRepository: shelfRootRepository
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

func doShelvePop(
    _ name: String,
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let notificationID = shelfBatchNotificationID(
        operation: .pop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        shelfFeedbackTitle(.pop),
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    Task.detached(priority: .userInitiated) {
        do {
            guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
            }
            let targetChangeList = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
            let applyResult = try shelfRepository.shelvePopDifferentiated(name: name)
            let appliedPaths = applyResult.appliedPaths
            let failedPaths = applyResult.failedPaths
            let st = try shelfRepository.status()
            try assignUnshelvedPaths(
                appliedPaths,
                to: targetChangeList,
                status: st,
                repo: shelfRepository
            )
            let cls = (try? shelfRepository.changelistList()) ?? []
            let ss = try shelfRepository.shelveList()
            let dsh = (try? shelfRepository.shelveDeletedList()) ?? []
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                if shelfRootSelectionIsPrimary(
                    selectedRootPath: resolvedRootPath,
                    primaryRootPath: self.primaryShelfRootPath
                ) {
                    self.entries = st
                    self.changeLists = cls
                }
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: ss,
                    deletedShelves: dsh
                )
                self.refreshAfterShelfMutation(repo: shelfRepository, paths: appliedPaths)
                if self.shelfPreviewName == name,
                   !ss.contains(where: { $0.name == name }),
                   shelfActionRootMatchesCurrentRoot(
                       requestedRootPath: resolvedRootPath,
                       currentRootPath: self.shelfPreviewRootPath ?? self.primaryShelfRootPath
                   ) {
                    self.shelfPreviewName = nil
                    self.shelfPreviewText = nil
                    self.showShelfPreview = false
                }
                let operationItem = FeedbackOperationItem(
                    scope: resolvedRootPath,
                    name: name,
                    state: patchApplyFeedbackState(applyResult),
                    detail: patchApplySummary(
                        applyResult,
                        successDetail: targetChangeList.map { "Applied → \($0)" } ?? "Applied",
                        failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                    ),
                    children: shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + name,
                        paths: shelf.paths,
                        result: applyResult,
                        successDetail: "Applied",
                        failureDetail: "Not applied"
                    )
                )
                if !patchApplyNeedsAttention(applyResult) {
                    self.feedbackCenter.success(
                        "Shelve pop completed",
                        detail: targetChangeList.map { "\(name) → \($0)" },
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Shelve pop partially completed",
                        detail: "\(name): \(appliedPaths.count) applied, \(failedPaths.count) not applied",
                        nextStep: "Review the remaining Shelf members and retry them separately.",
                        notificationID: notificationID
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    [operationItem],
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        } catch {
            if case let .ShelveApplyConflict(conflictName, paths) = error as? EngineError {
                if GitChangelistSettings.createAutomatically(from: .standard),
                   let shelf = try? shelfRepository.shelveList().first(where: { $0.name == conflictName }),
                   let target = try? automaticUnshelveTarget(for: shelf, repo: shelfRepository) {
                    _ = try? shelfRepository.shelveSetRestoreTarget(
                        name: conflictName,
                        targetChangeList: target
                    )
                }
                await MainActor.run {
                    self.presentShelveConflict(
                        name: conflictName,
                        paths: paths,
                        isPop: true,
                        changeListName: (try? shelfRepository.shelveRestoreInfo())?.targetChangeList,
                        repository: shelfRepository
                    )
                }
            } else {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Shelve pop failed",
                        detail: errorMessage(error),
                        nextStep: "The shelf was kept. Resolve the local conflict, then retry.",
                        notificationID: self.shelfBatchNotificationID(
                            operation: .pop,
                            rootPath: resolvedRootPath
                        )
                    )
                }
            }
        }
    }
}

/// Pop multiple active Shelves with the same non-dialog action semantics as
/// IntelliJ's PopShelfAction. Each list is applied and removed independently;
/// a conflict stops the queue so the persisted restore snapshot can be
/// resolved before another Shelf touches the same worktree.
func doShelvePopShelves(
    _ names: [String],
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    var seen = Set<String>()
    let uniqueNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !uniqueNames.isEmpty else { return }
    if uniqueNames.count == 1, let name = uniqueNames.first {
        doShelvePop(
            name,
            rootPath: resolvedRootPath,
            preservePreviousItems: preservePreviousItems
        )
        return
    }

    let notificationID = shelfBatchNotificationID(
        operation: .pop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Pop shelves",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Pop Shelf"
    )
    Task.detached(priority: .userInitiated) {
        var appliedDetails: [String] = []
        var appliedNames: [String] = []
        var consumedNames: [String] = []
        var mutatedPaths: [String] = []
        var failures: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        var conflict: (name: String, paths: [String], targetName: String?)?

        for (index, name) in uniqueNames.enumerated() {
            var shelfPaths: [String] = []
            do {
                guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                    throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
                }
                shelfPaths = shelf.paths
                let targetName = try automaticUnshelveTarget(for: shelf, repo: shelfRepository)
                let applyResult = try shelfRepository.shelvePopDifferentiated(name: name)
                let appliedPaths = applyResult.appliedPaths
                let failedPaths = applyResult.failedPaths
                if !(try shelfRepository.shelveList()).contains(where: { $0.name == name }) {
                    consumedNames.append(name)
                }
                mutatedPaths.append(contentsOf: appliedPaths)
                let status = try shelfRepository.status()
                try assignUnshelvedPaths(
                    appliedPaths,
                    to: targetName,
                    status: status,
                    repo: shelfRepository
                )
                if !patchApplyNeedsAttention(applyResult) {
                    appliedNames.append(name)
                    appliedDetails.append(
                        targetName.map { "\(name) → \($0)" } ?? name
                    )
                } else {
                    failures.append(
                        "\(name): \(appliedPaths.count) applied, \(failedPaths.count) not applied"
                    )
                }
                itemStates[name] = patchApplyFeedbackState(applyResult)
                itemDetails[name] = patchApplySummary(
                    applyResult,
                    successDetail: targetName.map { "Applied → \($0)" } ?? "Applied",
                    failureDetail: "\(appliedPaths.count) applied, \(failedPaths.count) not applied"
                )
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPaths,
                    result: applyResult,
                    successDetail: "Applied",
                    failureDetail: "Not applied"
                )
            } catch {
                if case let .ShelveApplyConflict(conflictName, paths) = error as? EngineError {
                    let targetName: String? = {
                        guard GitChangelistSettings.createAutomatically(from: .standard),
                              let shelf = try? shelfRepository.shelveList().first(where: { $0.name == conflictName })
                        else { return nil }
                        return try? automaticUnshelveTarget(for: shelf, repo: shelfRepository)
                    }()
                    if let targetName {
                        _ = try? shelfRepository.shelveSetRestoreTarget(
                            name: conflictName,
                            targetChangeList: targetName
                        )
                    }
                    let restoreInfo = (try? shelfRepository.shelveRestoreInfo()) ?? nil
                    let appliedPaths = restoreInfo?.appliedPaths ?? []
                    let conflictPaths = restoreInfo?.conflictPaths ?? paths
                    mutatedPaths.append(contentsOf: appliedPaths)
                    conflict = (conflictName, paths, targetName)
                    itemStates[conflictName] = .failed
                    itemDetails[conflictName] = "Conflict paused: \(paths.joined(separator: ", "))"
                    itemChildren[conflictName] = shelfOperationSubitems(
                        scope: resolvedRootPath + "\u{1f}" + conflictName,
                        paths: shelfPaths,
                        appliedPaths: Set(appliedPaths),
                        failedPaths: Set(conflictPaths),
                        successDetail: "Applied",
                        failureDetail: "Conflict paused"
                    )
                    await MainActor.run {
                        self.feedbackCenter.updateBatchProgress(
                            completed: index + 1,
                            total: uniqueNames.count,
                            phase: "Pop Shelf",
                            detail: conflictName
                        )
                    }
                    break
                }
                itemStates[name] = .failed
                itemDetails[name] = errorMessage(error)
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPaths,
                    state: .failed,
                    detail: errorMessage(error)
                )
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Pop Shelf",
                    detail: name
                )
            }
        }

        let finalStatus = (try? shelfRepository.status()) ?? []
        let nextChangeLists = (try? shelfRepository.changelistList()) ?? []
        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let appliedNamesSnapshot = appliedNames
        let consumedNamesSnapshot = consumedNames
        let mutatedPathsSnapshot = mutatedPaths
        let appliedDetailsSnapshot = appliedDetails
        let failuresSnapshot = failures
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        let conflictSnapshot = conflict
        await MainActor.run {
            guard shelfActionRootMatchesCurrentRoot(
                requestedRootPath: resolvedRootPath,
                currentRootPath: self.activeShelfRootPath
            ) else { return }
            let isPrimaryRoot = shelfRootSelectionIsPrimary(
                selectedRootPath: resolvedRootPath,
                primaryRootPath: self.primaryShelfRootPath
            )
            if isPrimaryRoot {
                self.entries = finalStatus
                self.changeLists = nextChangeLists
            }
            self.publishShelfSnapshot(
                rootPath: resolvedRootPath,
                shelves: nextShelves,
                deletedShelves: nextDeletedShelves,
                changeLists: nextChangeLists
            )
            self.refreshAfterShelfMutation(
                repo: shelfRepository,
                paths: mutatedPathsSnapshot
            )
            if !isPrimaryRoot {
                self.refreshAll(showFeedback: false)
            }
            if let previewName = self.shelfPreviewName,
               uniqueNames.contains(previewName),
               !nextShelves.contains(where: { $0.name == previewName }) {
                self.shelfPreviewName = nil
                self.shelfPreviewText = nil
                self.showShelfPreview = false
            }

            let retryNames = uniqueNames.filter {
                !appliedNamesSnapshot.contains($0)
                    && !consumedNamesSnapshot.contains($0)
                    && $0 != conflictSnapshot?.name
            }
            let retryAction = self.shelfBatchRetryFeedbackAction(
                names: retryNames,
                operation: .pop,
                targetName: nil,
                removeApplied: true,
                rootPath: resolvedRootPath
            )
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: uniqueNames,
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            let detail = appliedDetailsSnapshot.isEmpty
                ? "0/\(uniqueNames.count)"
                : appliedDetailsSnapshot.joined(separator: ", ")
            if let conflictSnapshot {
                let remaining = failuresSnapshot.isEmpty
                    ? nil
                    : failuresSnapshot.joined(separator: "\n")
                self.feedbackCenter.warning(
                    "Shelve pop paused",
                    detail: [detail, remaining].compactMap { $0 }.joined(separator: "\n"),
                    nextStep: "Resolve the restored local changes, then complete the Shelf pop.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
                self.presentShelveConflict(
                    name: conflictSnapshot.name,
                    paths: conflictSnapshot.paths,
                    isPop: true,
                    changeListName: conflictSnapshot.targetName,
                    repository: shelfRepository
                )
            } else if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelve pop completed",
                    detail: detail,
                    notificationID: notificationID
                )
            } else if !appliedDetailsSnapshot.isEmpty {
                self.feedbackCenter.warning(
                    "Shelves applied with warnings",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")]
                        .joined(separator: "\n"),
                    nextStep: "Review the remaining Shelves and retry them individually.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            } else {
                self.feedbackCenter.error(
                    "Shelf pop failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The remaining Shelves were kept. Resolve the local issue, then retry.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID,
                    localized: true
                )
            }
            self.feedbackCenter.attachOperationItems(
                operationItems,
                notificationID: notificationID,
                mergeWithExisting: preservePreviousItems
            )
        }
    }
}

/// Drop multiple active Shelves as one serial operation. IntelliJ treats a
/// multi-selection delete as one notification with per-list recovery actions;
/// serial execution keeps the repository lock and Recently Deleted ordering
/// deterministic while still allowing the remaining lists to be retried.
func doShelveDropShelves(
    _ names: [String],
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    var seenNames = Set<String>()
    let uniqueNames = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seenNames.insert($0).inserted }
    guard !uniqueNames.isEmpty else { return }
    if uniqueNames.count == 1, let name = uniqueNames.first {
        doShelveDrop(
            name,
            rootPath: resolvedRootPath,
            preservePreviousItems: preservePreviousItems
        )
        return
    }

    let notificationID = shelfBatchNotificationID(
        operation: .drop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Drop shelves",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Drop Shelf"
    )
    Task.detached(priority: .userInitiated) {
        var droppedNames: [String] = []
        var originalTimestamps: [String: Int64] = [:]
        var failures: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]

        for (index, name) in uniqueNames.enumerated() {
            do {
                guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == name }) else {
                    throw EngineError.GitOperation(message: "shelve: shelf not found '\(name)'")
                }
                originalTimestamps[name] = shelf.timestamp
                try shelfRepository.shelveDrop(name: name)
                droppedNames.append(name)
                itemStates[name] = .success
                itemDetails[name] = "Moved to Recently Deleted"
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelf.paths,
                    state: .success,
                    detail: "Moved to Recently Deleted"
                )
            } catch {
                itemStates[name] = .failed
                itemDetails[name] = errorMessage(error)
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: (try? shelfRepository.shelveList().first(where: { $0.name == name })?.paths) ?? [],
                    state: .failed,
                    detail: errorMessage(error)
                )
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Drop Shelf",
                    detail: name
                )
            }
        }

        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let droppedNamesSnapshot = droppedNames
        let originalTimestampsSnapshot = originalTimestamps
        let failuresSnapshot = failures
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
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
            if let previewName = self.shelfPreviewName,
               droppedNamesSnapshot.contains(previewName) {
                self.shelfPreviewName = nil
                self.shelfPreviewText = nil
                self.showShelfPreview = false
            }

            let batchUndoAction = self.shelfUndoDeletionsFeedbackAction(
                names: droppedNamesSnapshot,
                originalTimestamps: originalTimestampsSnapshot,
                rootPath: resolvedRootPath
            )
            let retryNames = uniqueNames.filter { !droppedNamesSnapshot.contains($0) }
            let retryAction = self.shelfBatchRetryFeedbackAction(
                names: retryNames,
                operation: .drop,
                targetName: nil,
                removeApplied: false,
                rootPath: resolvedRootPath
            )
            let additionalActions = (batchUndoAction.map { [$0] } ?? []) + (retryAction.map { [$0] } ?? [])
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: uniqueNames,
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            let droppedDetail = droppedNamesSnapshot.isEmpty
                ? "0/\(uniqueNames.count)"
                : "\(droppedNamesSnapshot.count)/\(uniqueNames.count): "
                    + droppedNamesSnapshot.joined(separator: ", ")

            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelves dropped",
                    detail: droppedDetail,
                    additionalActions: batchUndoAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            } else if droppedNamesSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Shelf drop failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The selected Shelves were kept. Resolve the reported issue and retry.",
                    additionalActions: retryAction.map { [$0] } ?? [],
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some Shelves dropped",
                    detail: [droppedDetail, failuresSnapshot.joined(separator: "\n")]
                        .joined(separator: "\n"),
                    nextStep: "The failed Shelves were kept. Retry them after resolving the reported issue.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            }
            self.feedbackCenter.attachOperationItems(
                operationItems,
                notificationID: notificationID,
                mergeWithExisting: preservePreviousItems
            )
        }
    }
}

/// Drop selected members from several active Shelves as one serialized
/// lifecycle operation. Every successful group remains undoable through one
/// timestamp-preserving batch action.
func doShelveDropPathGroups(
    _ groups: [ShelfPathDeleteGroup],
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let groups = normalizedShelfPathGroups(groups)
    guard !groups.isEmpty else { return }
    let notificationID = shelfMemberBatchNotificationID(
        operation: .drop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Drop Shelf changes",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: groups.count,
        phase: "Drop Shelf Changes"
    )
    Task.detached(priority: .userInitiated) {
        var completedKeys = Set<String>()
        var droppedNames: [String] = []
        var failures: [String] = []
        var restoreNames: [String] = []
        var restoreTimestamps: [String: Int64] = [:]
        var knownDeletedNames = Set((try? shelfRepository.shelveDeletedList().map(\.name)) ?? [])
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]

        for (index, group) in groups.enumerated() {
            do {
                guard let shelf = try shelfRepository.shelveList().first(where: { $0.name == group.shelfName }) else {
                    throw EngineError.GitOperation(message: "shelve: shelf not found '\(group.shelfName)'")
                }
                try shelfRepository.shelveDropPaths(name: group.shelfName, paths: group.paths)
                completedKeys.insert(shelfPathGroupKey(group))
                droppedNames.append(group.shelfName)
                itemStates[group.shelfName] = .success
                itemDetails[group.shelfName] = "Moved to Recently Deleted"
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .success,
                    detail: "Moved to Recently Deleted"
                )
                let currentDeleted = try shelfRepository.shelveDeletedList()
                for deleted in currentDeleted where !knownDeletedNames.contains(deleted.name) {
                    knownDeletedNames.insert(deleted.name)
                    restoreNames.append(deleted.name)
                    restoreTimestamps[deleted.name] = shelf.timestamp
                }
            } catch {
                failures.append("\(group.shelfName): \(errorMessage(error))")
                itemStates[group.shelfName] = .failed
                itemDetails[group.shelfName] = errorMessage(error)
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .failed,
                    detail: errorMessage(error)
                )
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: groups.count,
                    phase: "Drop Shelf Changes",
                    detail: group.shelfName
                )
            }
        }

        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let completedKeysSnapshot = completedKeys
        let droppedNamesSnapshot = droppedNames
        let failuresSnapshot = failures
        let restoreNamesSnapshot = restoreNames
        let restoreTimestampsSnapshot = restoreTimestamps
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        let retryGroups = groups.filter { !completedKeysSnapshot.contains(shelfPathGroupKey($0)) }
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
            if let previewName = self.shelfPreviewName,
               droppedNamesSnapshot.contains(previewName) {
                self.shelfPreviewName = nil
                self.shelfPreviewText = nil
                self.showShelfPreview = false
            }
            let retryAction = self.shelfMemberBatchRetryFeedbackAction(
                groups: retryGroups,
                operation: .drop,
                rootPath: resolvedRootPath
            )
            let undoAction = self.shelfUndoDeletionsFeedbackAction(
                names: restoreNamesSnapshot,
                originalTimestamps: restoreTimestampsSnapshot,
                rootPath: resolvedRootPath
            )
            let additionalActions = [undoAction, retryAction].compactMap { $0 }
            let detail = droppedNamesSnapshot.isEmpty
                ? "0/\(groups.count)"
                : "\(droppedNamesSnapshot.count)/\(groups.count): \(droppedNamesSnapshot.joined(separator: ", "))"
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: groups.map(\.shelfName),
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Shelf changes dropped",
                    detail: detail,
                    additionalActions: [undoAction].compactMap { $0 },
                    notificationID: notificationID
                )
            } else if droppedNamesSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Shelf changes drop failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The selected Shelf changes were kept. Resolve the reported issue and retry.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some Shelf changes were dropped",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")].joined(separator: "\n"),
                    nextStep: "Retry the remaining Shelf changes or use Undo to restore the dropped groups.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            }
            self.feedbackCenter.attachOperationItems(
                operationItems,
                notificationID: notificationID,
                mergeWithExisting: preservePreviousItems
            )
        }
    }
}

/// Permanently remove selected members from several Recently Deleted Shelves
/// as one serialized operation with one retryable notification.
func doShelveDeleteDeletedPathGroups(
    _ groups: [ShelfPathDeleteGroup],
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let groups = normalizedShelfPathGroups(groups)
    guard !groups.isEmpty else { return }
    let notificationID = shelfMemberBatchNotificationID(
        operation: .deleteDeleted,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Delete deleted Shelf changes permanently",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: groups.count,
        phase: "Delete Shelf Changes"
    )
    Task.detached(priority: .userInitiated) {
        var completedKeys = Set<String>()
        var deletedDetails: [String] = []
        var failures: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        for (index, group) in groups.enumerated() {
            do {
                try shelfRepository.shelveDeleteDeletedPaths(name: group.shelfName, paths: group.paths)
                completedKeys.insert(shelfPathGroupKey(group))
                deletedDetails.append("\(group.shelfName): \(group.paths.joined(separator: ", "))")
                itemStates[group.shelfName] = .success
                itemDetails[group.shelfName] = "Deleted permanently"
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .success,
                    detail: "Deleted permanently"
                )
            } catch {
                failures.append("\(group.shelfName): \(errorMessage(error))")
                itemStates[group.shelfName] = .failed
                itemDetails[group.shelfName] = errorMessage(error)
                itemChildren[group.shelfName] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + group.shelfName,
                    paths: group.paths,
                    state: .failed,
                    detail: errorMessage(error)
                )
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: groups.count,
                    phase: "Delete Shelf Changes",
                    detail: group.shelfName
                )
            }
        }
        let nextShelves = (try? shelfRepository.shelveList()) ?? []
        let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
        let completedKeysSnapshot = completedKeys
        let deletedDetailsSnapshot = deletedDetails
        let failuresSnapshot = failures
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        let retryGroups = groups.filter { !completedKeysSnapshot.contains(shelfPathGroupKey($0)) }
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
            let retryAction = self.shelfMemberBatchRetryFeedbackAction(
                groups: retryGroups,
                operation: .deleteDeleted,
                rootPath: resolvedRootPath
            )
            let additionalActions = [retryAction].compactMap { $0 }
            let detail = deletedDetailsSnapshot.isEmpty
                ? "0/\(groups.count)"
                : "\(completedKeysSnapshot.count)/\(groups.count): \(deletedDetailsSnapshot.joined(separator: "; "))"
            let operationItems = shelfOperationItems(
                rootPath: resolvedRootPath,
                names: groups.map(\.shelfName),
                states: itemStatesSnapshot,
                details: itemDetailsSnapshot,
                children: itemChildrenSnapshot
            )
            if failuresSnapshot.isEmpty {
                self.feedbackCenter.success(
                    "Deleted Shelf changes deleted permanently",
                    detail: detail,
                    notificationID: notificationID
                )
            } else if completedKeysSnapshot.isEmpty {
                self.feedbackCenter.error(
                    "Deleted Shelf changes deletion failed",
                    detail: failuresSnapshot.joined(separator: "\n"),
                    nextStep: "The deleted Shelf changes were kept. Resolve the reported issue and retry.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            } else {
                self.feedbackCenter.warning(
                    "Some deleted Shelf changes were deleted",
                    detail: [detail, failuresSnapshot.joined(separator: "\n")].joined(separator: "\n"),
                    nextStep: "Retry the remaining deleted Shelf changes.",
                    additionalActions: additionalActions,
                    notificationID: notificationID,
                    localized: true
                )
            }
            self.feedbackCenter.attachOperationItems(
                operationItems,
                notificationID: notificationID,
                mergeWithExisting: preservePreviousItems
            )
        }
    }
}

/// Permanently remove recycled Shelf lists through the explicit IntelliJ
/// "clean already unshelved" action. This does not touch active or Recently
/// Deleted shelves; the engine owns the lifecycle cutoff and ref cleanup.
func cleanRecycledShelves(rootPath: String? = nil) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let cutoff = Int64(Date().timeIntervalSince1970)
    let notificationID = shelfMetadataNotificationID(
        operation: "clean",
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        "Clear Already Unshelved",
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            let cleaned = try shelfRepository.shelveCleanRecycled(beforeTimestamp: cutoff)
            let nextShelves = try shelfRepository.shelveList()
            let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
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
                if cleaned.isEmpty {
                    self.feedbackCenter.warning(
                        "No already unshelved shelves to clear",
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.success(
                        "Already unshelved shelves cleared",
                        detail: cleaned.joined(separator: ", "),
                        notificationID: notificationID
                    )
                }
            }
        } catch {
            let nextShelves = (try? shelfRepository.shelveList()) ?? []
            let nextDeletedShelves = (try? shelfRepository.shelveDeletedList()) ?? []
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
                self.feedbackCenter.error(
                    "Clear already unshelved shelves failed",
                    detail: errorMessage(error),
                    nextStep: "The remaining shelves were kept. Retry the cleanup when the repository is ready.",
                    notificationID: notificationID
                )
            }
        }
    }
}

/// 仅删除 Shelf 中选中的成员；未选中的成员仍留在原 Shelf 中。
func doShelveDropPaths(
    _ name: String,
    _ paths: [String],
    rootPath: String? = nil
) {
    guard !paths.isEmpty,
          let context = shelfMutationContext(
              rootPath: rootPath,
              activeRootPath: activeShelfRootPath,
              primaryRootPath: primaryShelfRootPath,
              primaryRepository: repo,
              secondaryRepository: shelfRootRepository
          ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let scopedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelves : activeShelfList
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map { $0.name })
    let originalShelfTimestamp = scopedShelves.first(where: { $0.name == name })?.timestamp
    beginFeedbackOperation("Drop shelve changes")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveDropPaths(name: name, paths: paths)
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
                if self.shelfPreviewName == name,
                   shelfActionRootMatchesCurrentRoot(
                       requestedRootPath: resolvedRootPath,
                       currentRootPath: self.shelfPreviewRootPath ?? self.primaryShelfRootPath
                   ) {
                    self.shelfPreviewText = nil
                    self.showShelfPreview = false
                }
                let restoredName = dsh.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                if let restoredName {
                    let restoreAction = originalShelfTimestamp.map {
                        self.shelfUndoDeletedMembersFeedbackAction(
                            name: restoredName,
                            paths: paths,
                            originalTimestamp: $0,
                            rootPath: resolvedRootPath
                        )
                    } ?? self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        detail: paths.joined(separator: ", "),
                        additionalActions: [restoreAction],
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                } else {
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        detail: paths.joined(separator: ", "),
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Shelve drop failed",
                    detail: errorMessage(error),
                    nextStep: "The shelf was kept. Select a valid member and try again.",
                    notificationID: self.shelfBatchNotificationID(
                        operation: .drop,
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

func doShelveDrop(
    _ name: String,
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    let scopedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? shelves : activeShelfList
    let scopedDeletedShelves = shelfRootSelectionIsPrimary(
        selectedRootPath: resolvedRootPath,
        primaryRootPath: primaryShelfRootPath
    ) ? deletedShelves : activeDeletedShelfList
    let deletedShelfNamesBefore = Set(scopedDeletedShelves.map(\.name))
    let originalShelfTimestamp = scopedShelves.first(where: { $0.name == name })?.timestamp
    let originalShelfPaths = scopedShelves.first(where: { $0.name == name })?.paths ?? []
    let notificationID = shelfBatchNotificationID(
        operation: .drop,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        shelfFeedbackTitle(.drop),
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveDrop(name: name)
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
                if self.shelfPreviewName == name,
                   shelfActionRootMatchesCurrentRoot(
                       requestedRootPath: resolvedRootPath,
                       currentRootPath: self.shelfPreviewRootPath ?? self.primaryShelfRootPath
                   ) {
                    self.shelfPreviewName = nil
                    self.shelfPreviewText = nil
                    self.showShelfPreview = false
                }
                let restoredName = dsh.first(where: { !deletedShelfNamesBefore.contains($0.name) })?.name
                if let restoredName {
                    let restoreAction = originalShelfTimestamp.map {
                        self.shelfUndoDeletionFeedbackAction(
                            name: restoredName,
                            originalTimestamp: $0,
                            rootPath: resolvedRootPath
                        )
                    } ?? self.shelfRestoreFeedbackAction(
                        name: restoredName,
                        rootPath: resolvedRootPath
                    )
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        additionalActions: [restoreAction],
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                } else {
                    self.feedbackCenter.success(
                        "Shelve dropped",
                        notificationID: self.shelfBatchNotificationID(
                            operation: .drop,
                            rootPath: resolvedRootPath
                        )
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    [FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: .success,
                        detail: "Moved to Recently Deleted",
                        children: originalShelfPaths.map {
                            FeedbackOperationSubitem(
                                scope: resolvedRootPath + "\u{1f}" + name,
                                path: $0,
                                state: .success,
                                detail: "Moved to Recently Deleted"
                            )
                        }
                    )],
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Shelve drop failed",
                    detail: errorMessage(error),
                    nextStep: "The shelf was kept. Retry the deletion when the repository is ready.",
                    notificationID: self.shelfBatchNotificationID(
                        operation: .drop,
                        rootPath: resolvedRootPath
                    )
                )
                self.feedbackCenter.attachOperationItems(
                    [FeedbackOperationItem(
                        scope: resolvedRootPath,
                        name: name,
                        state: .failed,
                        detail: errorMessage(error),
                        children: originalShelfPaths.map {
                            FeedbackOperationSubitem(
                                scope: resolvedRootPath + "\u{1f}" + name,
                                path: $0,
                                state: .failed,
                                detail: errorMessage(error)
                            )
                        }
                    )],
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        }
    }
}

/// Permanently remove selected members from a Recently Deleted Shelf. The
/// remaining members stay recoverable; deleting the last member removes the
/// deleted Shelf itself.
func doShelveDeleteDeletedPaths(
    _ name: String,
    _ paths: [String],
    rootPath: String? = nil
) {
    guard !paths.isEmpty,
          let context = shelfMutationContext(
              rootPath: rootPath,
              activeRootPath: activeShelfRootPath,
              primaryRootPath: primaryShelfRootPath,
              primaryRepository: repo,
              secondaryRepository: shelfRootRepository
          ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    beginFeedbackOperation("Delete deleted Shelf members permanently")
    Task.detached(priority: .userInitiated) {
        do {
            try shelfRepository.shelveDeleteDeletedPaths(name: name, paths: paths)
            let ss = (try? shelfRepository.shelveList()) ?? []
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
                    paths.count == 1
                        ? "Deleted Shelf member deleted permanently"
                        : "Deleted Shelf members deleted permanently",
                    detail: "\(name): \(paths.joined(separator: ", "))",
                    notificationID: self.shelfDeletedMemberDeletionNotificationID(
                        rootPath: resolvedRootPath
                    )
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Delete deleted Shelf members failed",
                    detail: errorMessage(error),
                    nextStep: "The selected deleted Shelf members were kept. Retry the permanent deletion.",
                    additionalActions: [
                        self.shelfDeleteDeletedMembersFeedbackAction(
                            name: name,
                            paths: paths,
                            rootPath: resolvedRootPath
                        )
                    ],
                    notificationID: self.shelfDeletedMemberDeletionNotificationID(
                        rootPath: resolvedRootPath
                    )
                )
            }
        }
    }
}

/// Permanently delete a shelf from Recently Deleted after an explicit prompt.
func deleteDeletedShelve(_ name: String, rootPath: String? = nil) {
    deleteDeletedShelves([name], rootPath: rootPath)
}

/// Permanently delete one or more selected Recently Deleted shelves.
func deleteDeletedShelves(
    _ names: [String],
    confirm: Bool = true,
    rootPath: String? = nil,
    preservePreviousItems: Bool = false
) {
    guard let context = shelfMutationContext(
        rootPath: rootPath,
        activeRootPath: activeShelfRootPath,
        primaryRootPath: primaryShelfRootPath,
        primaryRepository: repo,
        secondaryRepository: shelfRootRepository
    ) else { return }
    let shelfRepository = context.repository
    let resolvedRootPath = context.rootPath
    var uniqueNames: [String] = []
    var seen = Set<String>()
    for name in names {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
        uniqueNames.append(trimmed)
    }
    guard !uniqueNames.isEmpty else { return }
    if confirm {
        let alert = NSAlert()
        alert.messageText = uniqueNames.count == 1
            ? "Delete Shelf Permanently?"
            : "Delete Shelves Permanently?"
        alert.informativeText = uniqueNames.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    let notificationID = shelfLifecycleNotificationID(
        operation: .deleteDeleted,
        rootPath: resolvedRootPath
    )
    beginFeedbackOperation(
        uniqueNames.count == 1 ? "Delete shelf permanently" : "Delete shelves permanently",
        notificationID: notificationID,
        preserveResultItems: preservePreviousItems
    )
    feedbackCenter.updateBatchProgress(
        completed: 0,
        total: uniqueNames.count,
        phase: "Delete Shelf"
    )
    Task.detached(priority: .userInitiated) { [uniqueNames] in
        let shelfPathsByName = Dictionary(
            uniqueKeysWithValues: ((try? shelfRepository.shelveDeletedList()) ?? []).map {
                ($0.name, $0.paths)
            }
        )
        var deleted: [String] = []
        var failures: [String] = []
        var failedNames: [String] = []
        var itemStates: [String: FeedbackResultState] = [:]
        var itemDetails: [String: String] = [:]
        var itemChildren: [String: [FeedbackOperationSubitem]] = [:]
        for (index, name) in uniqueNames.enumerated() {
            do {
                try shelfRepository.shelveDeleteDeleted(name: name)
                deleted.append(name)
                itemStates[name] = .success
                itemDetails[name] = "Deleted permanently"
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPathsByName[name] ?? [],
                    state: .success,
                    detail: "Deleted permanently"
                )
            } catch {
                failedNames.append(name)
                itemStates[name] = .failed
                itemDetails[name] = errorMessage(error)
                itemChildren[name] = shelfOperationSubitems(
                    scope: resolvedRootPath + "\u{1f}" + name,
                    paths: shelfPathsByName[name] ?? [],
                    state: .failed,
                    detail: errorMessage(error)
                )
                failures.append("\(name): \(errorMessage(error))")
            }
            await MainActor.run {
                self.feedbackCenter.updateBatchProgress(
                    completed: index + 1,
                    total: uniqueNames.count,
                    phase: "Delete Shelf",
                    detail: name
                )
            }
        }
        let deletedNames = deleted
        let failureMessages = failures
        let failedNamesSnapshot = failedNames
        let itemStatesSnapshot = itemStates
        let itemDetailsSnapshot = itemDetails
        let itemChildrenSnapshot = itemChildren
        do {
            let dsh = try shelfRepository.shelveDeletedList()
            await MainActor.run {
                guard shelfActionRootMatchesCurrentRoot(
                    requestedRootPath: resolvedRootPath,
                    currentRootPath: self.activeShelfRootPath
                ) else { return }
                let currentShelves = shelfRootSelectionIsPrimary(
                    selectedRootPath: resolvedRootPath,
                    primaryRootPath: self.primaryShelfRootPath
                ) ? self.shelves : self.activeShelfList
                self.publishShelfSnapshot(
                    rootPath: resolvedRootPath,
                    shelves: currentShelves,
                    deletedShelves: dsh
                )
                let retryAction = self.shelfLifecycleRetryFeedbackAction(
                    names: failedNamesSnapshot,
                    operation: .deleteDeleted,
                    rootPath: resolvedRootPath
                )
                let operationItems = shelfOperationItems(
                    rootPath: resolvedRootPath,
                    names: uniqueNames,
                    states: itemStatesSnapshot,
                    details: itemDetailsSnapshot,
                    children: itemChildrenSnapshot
                )
                if failureMessages.isEmpty {
                    self.feedbackCenter.success(
                        deletedNames.count == 1 ? "Shelf deleted permanently" : "Shelves deleted permanently",
                        detail: deletedNames.joined(separator: ", "),
                        notificationID: notificationID
                    )
                } else if deletedNames.isEmpty {
                    self.feedbackCenter.error(
                        "Permanent shelf deletion failed",
                        detail: failureMessages.joined(separator: "\n"),
                        nextStep: "The deleted shelves were kept. Retry after checking repository permissions.",
                        additionalActions: retryAction.map { [$0] } ?? [],
                        notificationID: notificationID
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Some shelves deleted permanently",
                        detail: "Deleted: \(deletedNames.joined(separator: ", "))\nFailed: \(failureMessages.joined(separator: ", "))",
                        nextStep: "The failed deleted shelves were kept. Retry after checking repository permissions.",
                        additionalActions: retryAction.map { [$0] } ?? [],
                        notificationID: notificationID
                    )
                }
                self.feedbackCenter.attachOperationItems(
                    operationItems,
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        } catch {
            await MainActor.run {
                let notificationID = self.shelfLifecycleNotificationID(
                    operation: .deleteDeleted,
                    rootPath: resolvedRootPath
                )
                self.feedbackCenter.error(
                    "Permanent shelf deletion failed",
                    detail: failureMessages.isEmpty ? errorMessage(error) : failureMessages.joined(separator: "\n"),
                    nextStep: "The deleted shelf was kept. Retry after checking repository permissions.",
                    additionalActions: self.shelfLifecycleRetryFeedbackAction(
                        names: failedNamesSnapshot,
                        operation: .deleteDeleted,
                        rootPath: resolvedRootPath
                    ).map { [$0] } ?? [],
                    notificationID: notificationID
                )
                self.feedbackCenter.attachOperationItems(
                    uniqueNames.map {
                        FeedbackOperationItem(
                            scope: resolvedRootPath,
                            name: $0,
                            state: itemStatesSnapshot[$0] ?? .failed,
                            detail: itemDetailsSnapshot[$0] ?? errorMessage(error)
                        )
                    },
                    notificationID: notificationID,
                    mergeWithExisting: preservePreviousItems
                )
            }
        }
    }
}

}
