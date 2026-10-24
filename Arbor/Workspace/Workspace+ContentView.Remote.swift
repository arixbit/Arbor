import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// 重新加载远程列表到状态（Configure Remotes Dialog 与推送选择共用）。
func loadRemotes() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let rs = try repo.remoteList()
            await MainActor.run {
                self.remoteWorkspace.remotes = rs
                self.restoreRemoteProtectedBranchPatterns(for: rs, projectPath: self.projectWorkspace.path)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Load remotes failed", detail: errorMessage(error), nextStep: "检查仓库配置后重试。")
            }
        }
    }
}

/// 打开指定 Git root 的 Configure Remotes，而不是复用当前窗口 repository
/// 的 remote 状态。Push 对话框和 Branches Popup 都通过这个入口进入。
func beginConfigureRemotes() {
    guard let projectPath = projectWorkspace.path else { return }
    beginFeedbackOperation("Load remotes")
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadRemoteConfigRoots(scanRoot: projectPath)
            await MainActor.run {
                self.remoteWorkspace.multiRootRemoteConfigAggregateContext = MultiRootRemoteConfigAggregateContext(roots: roots)
                self.feedbackCenter.success("Remotes loaded", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load remotes failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

/// REMOTE-001：保存当前编辑的远程配置（URL/push URL/refspec）。
func saveRemoteConfig() {
    guard let repo, !remoteWorkspace.name.isEmpty, !remoteWorkspace.url.isEmpty else { return }
    let name = remoteWorkspace.name.trimmingCharacters(in: .whitespaces)
    let url = remoteWorkspace.url.trimmingCharacters(in: .whitespaces)
    let pushUrl = remoteWorkspace.pushUrl.trimmingCharacters(in: .whitespaces)
    let fetchRefspec = remoteWorkspace.fetchRefspec.trimmingCharacters(in: .whitespaces)
    let pushRefspec = remoteWorkspace.pushRefspec.trimmingCharacters(in: .whitespaces)
    let broker = credentialAuth.broker
    beginFeedbackOperation("Save remote")
    Task.detached(priority: .userInitiated) {
        do {
            if let checkFailure = try remoteURLCheckFailure(repo: repo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                }
                return
            }
            try repo.remoteSetUrl(name: name, url: url)
            try repo.remoteSetPushUrl(name: name, pushUrl: pushUrl)
            try repo.remoteSetRefspecs(
                name: name,
                fetchRefspec: fetchRefspec.isEmpty ? nil : fetchRefspec,
                pushRefspec: pushRefspec.isEmpty ? nil : pushRefspec
            )
            await MainActor.run {
                self.feedbackCenter.success("Remote updated", detail: name)
            }
            await MainActor.run { self.loadRemotes() }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Save remote failed", detail: errorMessage(error), nextStep: "检查名称与 URL 后重试。")
            }
        }
    }
}

/// REMOTE-001：重命名远程（config + refs/remotes 一并处理）。
func remoteRename(_ old: String, _ new: String) {
    guard let repo, !new.isEmpty else { return }
    let newName = new.trimmingCharacters(in: .whitespaces)
    beginFeedbackOperation("Rename remote")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.remoteRename(old: old, new: newName)
            await MainActor.run { self.feedbackCenter.success("Remote renamed", detail: "\(old) → \(newName)") }
            await MainActor.run { self.loadRemotes() }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Rename remote failed", detail: errorMessage(error), nextStep: "检查名称后重试。")
            }
        }
    }
}

func remoteAdd(_ fetchAfterAdd: Bool = true) {
    guard let repo, !remoteWorkspace.name.isEmpty, !remoteWorkspace.url.isEmpty else { return }
    let name = remoteWorkspace.name, url = remoteWorkspace.url
    let broker = credentialAuth.broker
    beginFeedbackOperation("Add remote")
    Task.detached(priority: .userInitiated) {
        do {
            if let checkFailure = try remoteURLCheckFailure(repo: repo, url: url, broker: broker) {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Remote URL check failed",
                        detail: "\(url): \(checkFailure)",
                        nextStep: "Check the URL and authentication, then retry."
                    )
                }
                return
            }
            try repo.remoteAdd(name: name, url: url)
            let rs = try repo.remoteList()
            await MainActor.run {
                self.remoteWorkspace.remotes = rs; self.remoteWorkspace.name = ""; self.remoteWorkspace.url = ""
                self.feedbackCenter.success("Remote added", detail: name)
                if fetchAfterAdd {
                    self.doFetch(name)
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Add remote failed",
                    detail: errorMessage(error),
                    nextStep: "Check the remote name and URL, then retry."
                )
            }
        }
    }
}

func remoteRemove(_ name: String) {
    guard let repo else { return }
    guard confirmRemoteRemoval(name) else { return }
    beginFeedbackOperation("Remove remote")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.remoteRemove(name: name)
            let rs = try repo.remoteList()
            await MainActor.run {
                self.remoteWorkspace.remotes = rs
                self.feedbackCenter.success("Remote removed", detail: name)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Remove remote failed",
                    detail: errorMessage(error),
                    nextStep: "Check the remote configuration, then retry."
                )
            }
        }
    }
}

func confirmRemoteRemoval(_ name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(localized: "Remove remote?")
    alert.informativeText = String(localized: "This removes the remote configuration and its remote-tracking branches.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

nonisolated func friendlyRemoteError(_ error: Error) -> String {
    let full = errorMessage(error)
    let raw = full.count > 4000 ? String(full.prefix(4000)) + "\n…" : full
    let lower = raw.lowercased()
    if lower.contains("ssh host key changed")
        || lower.contains("remote host identification has changed")
    {
        return raw + "\nSSH 安全阻断：远端 host key 已变化。请先确认服务器身份，在 Git SSH Settings 检查 Known Hosts 后再重试。"
    }
    if lower.contains("authentication failed")
        || lower.contains("invalid username or token")
        || lower.contains("invalid credentials")
        || lower.contains("could not read username")
        || lower.contains("permission denied (publickey)")
        || lower.contains("publickey") {
        return raw + "\n认证失败：请检查 SSH key，或配置 git credential.helper。"
    }
    return raw
}

}
