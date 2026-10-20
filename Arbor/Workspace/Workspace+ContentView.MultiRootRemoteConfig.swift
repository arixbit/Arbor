import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func loadMultiRootRemoteConfigAggregate() {
    guard let projectPath = projectWorkspace.path else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadRemoteConfigRoots(scanRoot: projectPath)
            await MainActor.run {
                guard self.remoteWorkspace.multiRootRemoteConfigAggregateContext != nil else { return }
                self.remoteWorkspace.multiRootRemoteConfigAggregateContext = MultiRootRemoteConfigAggregateContext(roots: roots)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Refresh remotes failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func beginMultiRootRemoteConfig(rootPath: String, selectedRemote: String? = nil) {
    beginFeedbackOperation("Load root remotes")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let rootRemotes = try rootRepo.remoteList()
            let selected = selectedRemote.flatMap { name in
                rootRemotes.first(where: { $0.name == name })
            }
            await MainActor.run {
                self.remoteWorkspace.multiRootRemoteName = selected?.name ?? ""
                self.remoteWorkspace.multiRootRemoteURL = selected?.url ?? ""
                self.remoteWorkspace.multiRootRemotePushURL = selected?.pushUrl ?? ""
                self.remoteWorkspace.multiRootRemoteFetchRefspec = selected?.fetchRefspec ?? ""
                self.remoteWorkspace.multiRootRemotePushRefspec = selected?.pushRefspec ?? ""
                self.remoteWorkspace.multiRootRemoteConfigContext = MultiRootRemoteConfigContext(
                    rootPath: rootPath,
                    remotes: rootRemotes
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load root remotes failed",
                    detail: "\(rootPath): \(errorMessage(error))",
                    nextStep: "Check the selected Git root and retry."
                )
            }
        }
    }
}

func loadMultiRootRemoteConfig(rootPath: String) {
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let rootRemotes = try rootRepo.remoteList()
            await MainActor.run {
                guard self.remoteWorkspace.multiRootRemoteConfigContext?.rootPath == rootPath else { return }
                self.remoteWorkspace.multiRootRemoteConfigContext = MultiRootRemoteConfigContext(
                    rootPath: rootPath,
                    remotes: rootRemotes
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Refresh root remotes failed",
                    detail: "\(rootPath): \(errorMessage(error))"
                )
            }
        }
    }
}

func saveRemoteConfigInRoot(rootPath: String) {
    let name = remoteWorkspace.multiRootRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = remoteWorkspace.multiRootRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else { return }
    let pushURL = remoteWorkspace.multiRootRemotePushURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let fetchRefspec = remoteWorkspace.multiRootRemoteFetchRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    let pushRefspec = remoteWorkspace.multiRootRemotePushRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    let broker = credentialAuth.broker
    beginFeedbackOperation("Save root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if let checkFailure = try remoteURLCheckFailure(repo: rootRepo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                }
                return
            }
            try rootRepo.remoteSetUrl(name: name, url: url)
            try rootRepo.remoteSetPushUrl(name: name, pushUrl: pushURL)
            try rootRepo.remoteSetRefspecs(
                name: name,
                fetchRefspec: fetchRefspec.isEmpty ? nil : fetchRefspec,
                pushRefspec: pushRefspec.isEmpty ? nil : pushRefspec
            )
            await MainActor.run {
                self.feedbackCenter.success("Root remote updated", detail: "\(name) · \(rootPath)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Save root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the URL and refspec, then retry."
                )
            }
        }
    }
}

func addRemoteInRoot(rootPath: String, fetchAfterAdd: Bool = true) {
    let name = remoteWorkspace.multiRootRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = remoteWorkspace.multiRootRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else { return }
    addRemoteInRoot(rootPath: rootPath, name: name, url: url, fetchAfterAdd: fetchAfterAdd)
}

func addRemoteInRoot(
    rootPath: String,
    name: String,
    url: String,
    fetchAfterAdd: Bool = true,
    completion: @escaping (Bool) -> Void = { _ in }
) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else {
        completion(false)
        return
    }
    let broker = credentialAuth.broker
    beginFeedbackOperation("Add root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if let checkFailure = try remoteURLCheckFailure(repo: rootRepo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                    completion(false)
                }
                return
            }
            try rootRepo.remoteAdd(name: name, url: url)
            await MainActor.run {
                if self.remoteWorkspace.multiRootRemoteConfigContext?.rootPath == rootPath {
                    self.remoteWorkspace.multiRootRemoteName = ""
                    self.remoteWorkspace.multiRootRemoteURL = ""
                    self.remoteWorkspace.multiRootRemotePushURL = ""
                    self.remoteWorkspace.multiRootRemoteFetchRefspec = ""
                    self.remoteWorkspace.multiRootRemotePushRefspec = ""
                }
                self.feedbackCenter.success("Root remote added", detail: "\(name) · \(rootPath)")
                completion(true)
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
                if fetchAfterAdd {
                    self.fetchRemoteInRoot(rootPath: rootPath, remote: name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Add root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the remote name and URL, then retry."
                )
                completion(false)
            }
        }
    }
}

func updateRemoteInRoot(
    rootPath: String,
    oldName: String,
    name: String,
    url: String,
    pushURL: String,
    fetchRefspec: String,
    pushRefspec: String,
    fetchAfterUpdate: Bool,
    completion: @escaping (Bool) -> Void = { _ in }
) {
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let pushURL = pushURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let fetchRefspec = fetchRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    let pushRefspec = pushRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldName.isEmpty, !name.isEmpty, !url.isEmpty else {
        completion(false)
        return
    }
    let broker = credentialAuth.broker
    beginFeedbackOperation("Update root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if let checkFailure = try remoteURLCheckFailure(repo: rootRepo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                    completion(false)
                }
                return
            }
            if oldName != name {
                try rootRepo.remoteRename(old: oldName, new: name)
            }
            try rootRepo.remoteSetUrl(name: name, url: url)
            try rootRepo.remoteSetPushUrl(name: name, pushUrl: pushURL)
            try rootRepo.remoteSetRefspecs(
                name: name,
                fetchRefspec: fetchRefspec.isEmpty ? nil : fetchRefspec,
                pushRefspec: pushRefspec.isEmpty ? nil : pushRefspec
            )
            await MainActor.run {
                self.feedbackCenter.success("Root remote updated", detail: "\(name) · \(rootPath)")
                completion(true)
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
                if fetchAfterUpdate {
                    self.fetchRemoteInRoot(rootPath: rootPath, remote: name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Update root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the remote name, URL, and refspec, then retry."
                )
                completion(false)
            }
        }
    }
}

func removeRemoteInRoot(rootPath: String, name: String) {
    guard confirmRemoteRemoval(name) else { return }
    beginFeedbackOperation("Remove root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.remoteRemove(name: name)
            await MainActor.run {
                self.feedbackCenter.success("Root remote removed", detail: "\(name) · \(rootPath)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Remove root remote failed",
                    detail: "\(name) · \(rootPath): \(errorMessage(error))"
                )
            }
        }
    }
}

/// IntelliJ's MultipleGroupActions removes each selected remote group while
/// retaining the owning Git root. A failure in one root must not prevent the
/// other selected remotes from being attempted.
func removeSelectedRemotesInRoots(_ groups: [BranchDashboardRemoteGroup]) {
    let selected = Array(Set(groups)).sorted {
        if $0.rootPath == $1.rootPath { return $0.name < $1.name }
        return $0.rootPath < $1.rootPath
    }
    guard !selected.isEmpty, !multiRootWorkspace.running else { return }

    let alert = NSAlert()
    alert.messageText = "Remove selected remotes?"
    alert.informativeText = selected
        .map { "\($0.name) · \($0.rootPath)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    multiRootWorkspace.running = true
    beginFeedbackOperation("Remove selected remotes")
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        for group in selected {
            do {
                let rootRepo = try openRepository(path: group.rootPath)
                try rootRepo.remoteRemove(name: group.name)
                results.append(
                    RootOperationResult(
                        rootPath: group.rootPath,
                        displayName: displayNames[group.rootPath] ?? group.rootPath,
                        success: true,
                        skipped: false,
                        message: "Removed \(group.name)"
                    )
                )
            } catch {
                results.append(
                    RootOperationResult(
                        rootPath: group.rootPath,
                        displayName: displayNames[group.rootPath] ?? group.rootPath,
                        success: false,
                        skipped: false,
                        message: "\(group.name): \(errorMessage(error))"
                    )
                )
            }
        }

        let completedResults = results
        let completedFailures = completedResults.filter { !$0.success }
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.multiRootWorkspace.results = completedResults
            self.loadMultiRootRemoteConfigAggregate()
            self.loadMultiRoots()
            if completedFailures.isEmpty {
                self.feedbackCenter.success(
                    "Selected remotes removed",
                    detail: "\(selected.count) remotes"
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Selected remote removal partially completed",
                    detail: completedFailures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                    nextStep: "Review the failed remote removals and retry them individually."
                )
            }
        }
    }
}

func renameRemoteInRoot(rootPath: String, old: String, new: String) {
    let newName = new.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != old else { return }
    beginFeedbackOperation("Rename root remote")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.remoteRename(old: old, new: newName)
            await MainActor.run {
                self.remoteWorkspace.multiRootRemoteName = newName
                self.feedbackCenter.success("Root remote renamed", detail: "\(old) → \(newName) · \(rootPath)")
                self.loadMultiRootRemoteConfig(rootPath: rootPath)
                self.loadMultiRootRemoteConfigAggregate()
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Rename root remote failed",
                    detail: "\(old) → \(newName) · \(rootPath): \(errorMessage(error))"
                )
            }
        }
    }
}

}
