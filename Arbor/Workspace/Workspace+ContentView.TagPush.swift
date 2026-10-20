import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func pushTag(_ tag: String, remote selectedRemote: String? = nil) {
    guard let repo,
          let remote = resolveSelectedRemoteName(
              selectedRemote: selectedRemote,
              availableRemoteNames: remoteWorkspace.remotes.map(\.name)
          ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing the tag",
            detail: "Multiple remotes are configured for this Git root."
        )
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push tag", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.tagPushWithAuthAndCancel(
                remote: remote,
                tag: tag,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run { self.tagWorkspace.feedback = "已推送 \(tag)" }
        } catch {
            await MainActor.run {
                self.tagWorkspace.feedback = friendlyRemoteError(error)
                if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
            }
        }
    }
}

func pushTagInRoot(rootPath: String, name: String, remote selectedRemote: String? = nil) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push tag", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let remoteNames = try rootRepo.remoteList().map(\.name)
            guard let remote = resolveSelectedRemoteName(
                selectedRemote: selectedRemote,
                availableRemoteNames: remoteNames
            ) else {
                throw NSError(
                    domain: "Arbor.PushTags",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: selectedRemote == nil
                            ? "Multiple remotes are configured; choose a remote before pushing the tag."
                            : "The selected remote is no longer configured."
                    ]
                )
            }
            try rootRepo.tagPushWithAuthAndCancel(
                remote: remote,
                tag: name,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Tag pushed", detail: "\(name) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Push tag failed", detail: "\(name) · \(rootPath): \(friendlyRemoteError(error))")
                if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
            }
        }
    }
}

/// Push every local tag to the selected root's explicitly selected or only
/// configured remote. This mirrors IntelliJ's Git.Push.Tags action while
/// keeping the operation non-forceful:
/// divergent remote tags are rejected by Git instead of being overwritten.
func pushAllTagsInRoot(rootPath: String, remote selectedRemote: String? = nil) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push all tags", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let remoteNames = try rootRepo.remoteList().map(\.name)
            guard let remote = resolveSelectedRemoteName(
                selectedRemote: selectedRemote,
                availableRemoteNames: remoteNames
            ) else {
                throw NSError(
                    domain: "Arbor.PushTags",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: selectedRemote == nil
                            ? "Multiple remotes are configured; choose a remote before pushing all tags."
                            : "The selected remote is no longer configured."
                    ]
                )
            }
            try rootRepo.pushRefspecWithAuthAndCancel(
                remote: remote,
                refspec: "refs/tags/*:refs/tags/*",
                force: false,
                forceWithLease: false,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("All tags pushed", detail: "\(remote) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error(
                    "Push all tags failed",
                    detail: "\(rootPath): \(friendlyRemoteError(error))",
                    nextStep: "Check the remote and tag names, then retry."
                )
            }
        }
    }
}

/// Phase 5：推送 tag 到远程。
func tagPushToRemote(_ name: String, remote selectedRemote: String? = nil) {
    guard let repo,
          let remote = resolveSelectedRemoteName(
              selectedRemote: selectedRemote,
              availableRemoteNames: remoteWorkspace.remotes.map(\.name)
          ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing the tag",
            detail: "Multiple remotes are configured for this Git root."
        )
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push tag", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.tagPushWithAuthAndCancel(
                remote: remote,
                tag: name,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run { self.feedbackCenter.success("Tag pushed", detail: "\(remote)/\(name)") }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Push tag failed", detail: friendlyRemoteError(error), nextStep: "检查远程与 tag 后重试。")
                if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
            }
        }
    }
}

/// Push all local tags to the current root's explicitly selected or only configured remote.
func pushAllTagsToRemote(remote selectedRemote: String? = nil) {
    guard let repo,
          let remote = resolveSelectedRemoteName(
              selectedRemote: selectedRemote,
              availableRemoteNames: remoteWorkspace.remotes.map(\.name)
          ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing all tags",
            detail: "Multiple remotes are configured for this Git root."
        )
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Push all tags", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.pushRefspecWithAuthAndCancel(
                remote: remote,
                refspec: "refs/tags/*:refs/tags/*",
                force: false,
                forceWithLease: false,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.feedbackCenter.success("All tags pushed", detail: remote)
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Push all tags failed",
                    detail: friendlyRemoteError(error),
                    nextStep: "Check the remote and tag names, then retry."
                )
            }
        }
    }
}

}
