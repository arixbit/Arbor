import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func chooseCloneParentDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "选择父目录"
    panel.directoryURL = URL(fileURLWithPath: cloneParentDirectory)
    if panel.runModal() == .OK, let url = panel.url {
        cloneParentDirectory = url.standardizedFileURL.path
    }
}

func cloneRepositoryFromDialog() {
    guard !cloneInProgress else { return }
    let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let parent = cloneParentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    var directoryName = cloneDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    if directoryName.isEmpty {
        let lastComponent = url
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .last
            .map(String.init) ?? "cloned-repository"
        directoryName = lastComponent.hasSuffix(".git")
            ? String(lastComponent.dropLast(4))
            : lastComponent
    }
    guard !url.isEmpty, !parent.isEmpty, !directoryName.isEmpty else { return }
    let requestedDepth: UInt32?
    if cloneShallow {
        guard let parsedDepth = UInt32(cloneDepth.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsedDepth > 0 else {
            feedbackCenter.error("Clone Git repository failed", detail: "Shallow clone depth must be a positive integer.", nextStep: "Enter a depth greater than zero and retry.")
            return
        }
        requestedDepth = parsedDepth
    } else {
        requestedDepth = nil
    }
    let destination = URL(fileURLWithPath: parent).appendingPathComponent(directoryName).path
    let recursive = cloneRecursiveSubmodules
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    cloneRequestGeneration &+= 1
    let generation = cloneRequestGeneration
    cloneInProgress = true
    cloneCancelling = false
    cloneCancelHandle = cancel
    beginFeedbackOperation("Clone Git repository")
    Task.detached(priority: .userInitiated) {
        do {
            let clonedPath = try cloneRepositoryWithAuthOptionsAndCancel(
                url: url,
                destination: destination,
                recursiveSubmodules: recursive,
                broker: broker,
                depth: requestedDepth,
                cancel: cancel
            )
            await MainActor.run {
                guard self.cloneRequestGeneration == generation else { return }
                self.cloneInProgress = false
                self.cloneCancelling = false
                self.cloneCancelHandle = nil
                self.showCloneDialog = false
                self.cloneURL = ""
                self.cloneDirectoryName = ""
                self.cloneShallow = false
                self.cloneDepth = "1"
                self.feedbackCenter.success("Git repository cloned", detail: clonedPath)
                self.path = clonedPath
            }
            await MainActor.run { self.requestOpenProject(clonedPath) }
        } catch {
            await MainActor.run {
                guard self.cloneRequestGeneration == generation else { return }
                self.cloneInProgress = false
                self.cloneCancelling = false
                self.cloneCancelHandle = nil
                if cancel.isCancelled() {
                    self.feedbackCenter.warning(
                        "Clone cancelled",
                        detail: destination,
                        nextStep: "Adjust the clone options and retry when ready."
                    )
                    return
                }
                self.loadError = errorMessage(error)
                self.feedbackCenter.error("Clone Git repository failed", detail: friendlyRemoteError(error), nextStep: "Check the URL, destination, and authentication, then retry.")
            }
        }
    }
}

func cancelCloneRepositoryFromDialog() {
    guard cloneInProgress else {
        showCloneDialog = false
        return
    }
    guard !cloneCancelling else { return }
    cloneCancelling = true
    cloneCancelHandle?.cancel()
}

}
