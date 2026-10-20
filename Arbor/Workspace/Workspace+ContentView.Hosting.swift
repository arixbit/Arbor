import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func showHostingAuthPromptIfNeeded(for results: [RootOperationResult]) {
    guard results.contains(where: { !$0.success && arborAuthenticationFailureMessage($0.message) }) else {
        return
    }
    showHostingAuthPrompt = true
}

/// 在所选 hosted remote 打开 PR / merge request 创建页。
func openPR(_ branch: String, remote: RemoteInfo) {
    guard let repo else {
        feedbackCenter.error(
            "Open pull request unavailable",
            detail: "The Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    let url = remote.url
    let branchName = branch
    Task.detached(priority: .userInitiated) {
        let link = repo.prUrl(remoteUrl: url, branch: branchName)
        await MainActor.run {
            guard let link else {
                self.feedbackCenter.error(
                    "Open pull request unavailable",
                    detail: "The selected remote does not expose a pull request URL.",
                    nextStep: "Choose another hosted remote or configure a supported remote."
                )
                return
            }
            guard let nsUrl = URL(string: link), NSWorkspace.shared.open(nsUrl) else {
                self.feedbackCenter.error(
                    "Open pull request failed",
                    detail: link,
                    nextStep: "Copy the branch name and open the pull request page manually."
                )
                return
            }
        }
    }
}

}
