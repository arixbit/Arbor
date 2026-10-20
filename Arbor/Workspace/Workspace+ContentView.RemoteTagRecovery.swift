import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func deleteRemoteTagsFromRecovery(_ contexts: [TagDeleteRecoveryContext]) {
    guard !contexts.isEmpty else { return }
    let remotes: [(TagDeleteRecoveryContext, RemoteInfo)] = contexts.flatMap { context in
        let repositoryRemotes = (try? context.repo.remoteList()) ?? []
        return repositoryRemotes.map { remote in (context, remote) }
    }
    guard !remotes.isEmpty else {
        feedbackCenter.warning("No remotes configured", detail: contexts.first?.tag.name ?? "")
        return
    }
    tagWorkspace.multiRootDeleteRecovery = nil
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete multi-root remote tags", cancelHandle: cancel)
    let broker = credentialAuth.broker
    Task.detached(priority: .userInitiated) {
        var deleted: [String] = []
        var missing: [String] = []
        var failures: [String] = []
        var cancelled = false
        for (context, remote) in remotes {
            if cancel.isCancelled() {
                cancelled = true
                break
            }
            do {
                let didDelete = try context.repo.deleteRemoteTagWithAuthLeaseAndCancel(
                    remote: remote.name,
                    tag: context.tag.name,
                    expectedObjectId: context.tag.objectId,
                    broker: broker,
                    cancel: cancel
                )
                let location = "\(context.rootPath ?? String(localized: "Repository")) · \(remote.name)"
                if didDelete {
                    deleted.append(location)
                } else {
                    missing.append(location)
                }
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")) · \(remote.name): \(friendlyRemoteError(error))"
                )
            }
        }
        let deletedRemotes = deleted
        let missingRemotes = missing
        let failuresToReport = failures
        let wasCancelled = cancelled
        await MainActor.run {
            if failuresToReport.isEmpty && !wasCancelled {
                self.loadMultiRoots()
                let detail = deletedRemotes.isEmpty
                    ? "Tag was not present on configured remotes"
                    : deletedRemotes.joined(separator: "\n")
                if !missingRemotes.isEmpty && !deletedRemotes.isEmpty {
                    self.feedbackCenter.success(
                        "Multi-root remote tag deletion completed",
                        detail: "\(detail)\nAlready absent: \(missingRemotes.joined(separator: ", "))"
                    )
                } else {
                    self.feedbackCenter.success("Multi-root remote tag deletion completed", detail: detail)
                }
            } else if wasCancelled {
                self.tagWorkspace.multiRootDeleteRecovery = MultiRootTagDeleteRecoveryContext(
                    tagName: contexts.first?.tag.name ?? "",
                    contexts: contexts
                )
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Multi-root remote tag deletion canceled",
                    detail: "Deleted \(deletedRemotes.count); already absent \(missingRemotes.count).",
                    nextStep: "Retry the recovery action to process the remaining remotes."
                )
            } else {
                self.tagWorkspace.multiRootDeleteRecovery = MultiRootTagDeleteRecoveryContext(
                    tagName: contexts.first?.tag.name ?? "",
                    contexts: contexts
                )
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    "Multi-root remote tag deletion partially completed",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the failed remotes and retry the action."
                )
            }
        }
    }
}

/// IntelliJ's local tag deletion notification exposes a follow-up action that
/// removes the same tag from every configured remote. Each remote is checked
/// independently; an already absent tag is successful, while a real push
/// failure keeps the recovery surface open for another attempt.
func deleteRemoteTagFromRecovery(_ context: TagDeleteRecoveryContext) {
    let remotes = context.remotes
    guard !remotes.isEmpty else {
        feedbackCenter.warning("No remotes configured", detail: context.tag.name)
        return
    }
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete remote tag", cancelHandle: cancel)
    let broker = credentialAuth.broker
    Task.detached(priority: .userInitiated) {
        var deleted: [String] = []
        var missing: [String] = []
        var failures: [String] = []
        var cancelled = false
        for remote in remotes {
            if cancel.isCancelled() {
                cancelled = true
                break
            }
            do {
                let didDelete = try context.repo.deleteRemoteTagWithAuthLeaseAndCancel(
                    remote: remote.name,
                    tag: context.tag.name,
                    expectedObjectId: context.tag.objectId,
                    broker: broker,
                    cancel: cancel
                )
                if didDelete {
                    deleted.append(remote.name)
                } else {
                    missing.append(remote.name)
                }
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                failures.append("\(remote.name): \(friendlyRemoteError(error))")
            }
        }
        let deletedRemotes = deleted
        let missingRemotes = missing
        let failuresToReport = failures
        let wasCancelled = cancelled
        await MainActor.run {
            if failuresToReport.isEmpty && !wasCancelled {
                self.tagWorkspace.deleteRecovery = nil
                self.refreshAll(showFeedback: false)
                let detail = deletedRemotes.isEmpty
                    ? "\(context.tag.name) was not present on configured remotes"
                    : "\(context.tag.name) · \(deletedRemotes.joined(separator: ", "))"
                self.feedbackCenter.success("Remote tag deletion completed", detail: detail)
            } else if wasCancelled {
                self.feedbackCenter.warning(
                    "Remote tag deletion canceled",
                    detail: "Deleted \(deletedRemotes.count); already absent \(missingRemotes.count).",
                    nextStep: "Retry the recovery action to process the remaining remotes."
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                let missingDetail = missingRemotes.isEmpty
                    ? ""
                    : "\nAlready absent: \(missingRemotes.joined(separator: ", "))"
                self.feedbackCenter.warning(
                    "Remote tag deletion partially completed",
                    detail: failuresToReport.joined(separator: "\n") + missingDetail,
                    nextStep: "Review the failed remotes and retry the action."
                )
            }
        }
    }
}

}
