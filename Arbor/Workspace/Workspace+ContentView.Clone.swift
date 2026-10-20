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
    panel.directoryURL = URL(fileURLWithPath: cloneWorkspace.parentDirectory)
    if panel.runModal() == .OK, let url = panel.url {
        cloneWorkspace.parentDirectory = url.standardizedFileURL.path
    }
}

func cloneRepositoryFromDialog() {
    guard !cloneWorkspace.inProgress else { return }
    let url = cloneWorkspace.url.trimmingCharacters(in: .whitespacesAndNewlines)
    let parent = cloneWorkspace.parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    var directoryName = cloneWorkspace.directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
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
    if cloneWorkspace.shallow {
        guard let parsedDepth = UInt32(cloneWorkspace.depth.trimmingCharacters(in: .whitespacesAndNewlines)),
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
    cloneWorkspace.requestGeneration &+= 1
    let generation = cloneWorkspace.requestGeneration
    cloneWorkspace.inProgress = true
    cloneWorkspace.cancelling = false
    cloneWorkspace.cancelHandle = cancel
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
                guard self.cloneWorkspace.requestGeneration == generation else { return }
                self.cloneWorkspace.inProgress = false
                self.cloneWorkspace.cancelling = false
                self.cloneWorkspace.cancelHandle = nil
                self.cloneWorkspace.showDialog = false
                self.cloneWorkspace.url = ""
                self.cloneWorkspace.directoryName = ""
                self.cloneWorkspace.shallow = false
                self.cloneWorkspace.depth = "1"
                self.feedbackCenter.success("Git repository cloned", detail: clonedPath)
                self.projectWorkspace.inputPath = clonedPath
            }
            await MainActor.run { self.requestOpenProject(clonedPath) }
        } catch {
            await MainActor.run {
                guard self.cloneWorkspace.requestGeneration == generation else { return }
                self.cloneWorkspace.inProgress = false
                self.cloneWorkspace.cancelling = false
                self.cloneWorkspace.cancelHandle = nil
                if cancel.isCancelled() {
                    self.feedbackCenter.warning(
                        "Clone cancelled",
                        detail: destination,
                        nextStep: "Adjust the clone options and retry when ready."
                    )
                    return
                }
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Clone Git repository failed", detail: friendlyRemoteError(error), nextStep: "Check the URL, destination, and authentication, then retry.")
            }
        }
    }
}

func cancelCloneRepositoryFromDialog() {
    guard cloneWorkspace.inProgress else {
        cloneWorkspace.showDialog = false
        return
    }
    guard !cloneWorkspace.cancelling else { return }
    cloneWorkspace.cancelling = true
    cloneWorkspace.cancelHandle?.cancel()
}

}
