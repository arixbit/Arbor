import SwiftUI

/// Git hooks 面板的状态与动作。所有磁盘读写放在后台线程，回到主线程更新
/// 列表与编辑器，和 LFS 面板保持同一套 busy/feedback 约定。
extension ContentView {
    func presentHooksPanel() {
        hooksWorkspace.showPanel = true
        reloadGitHooks()
    }

    func reloadGitHooks() {
        guard let repo else { return }
        hooksWorkspace.busy = true
        Task.detached(priority: .userInitiated) {
            let location = repo.gitHooksLocation()
            let hooks = (try? repo.gitHooks()) ?? []
            await MainActor.run {
                self.hooksWorkspace.location = location
                self.hooksWorkspace.hooks = hooks
                self.hooksWorkspace.busy = false
                // 选中项消失时清空编辑器，避免对已删除的 hook 保存。
                if let selected = self.hooksWorkspace.selection,
                   !hooks.contains(where: { $0.name == selected }) {
                    self.hooksWorkspace.selection = nil
                    self.hooksWorkspace.contents = nil
                    self.hooksWorkspace.draft = ""
                }
            }
        }
    }

    func selectGitHook(_ name: String?) {
        guard let name, let repo else {
            hooksWorkspace.contents = nil
            hooksWorkspace.draft = ""
            return
        }
        hooksWorkspace.busy = true
        Task.detached(priority: .userInitiated) {
            let contents = try? repo.gitHookContents(name: name)
            await MainActor.run {
                self.hooksWorkspace.contents = contents
                self.hooksWorkspace.draft = contents?.content ?? ""
                self.hooksWorkspace.busy = false
            }
        }
    }

    private func runHookAction(
        _ title: String,
        successDetail: String? = nil,
        operation: @escaping (Repository) throws -> Void
    ) {
        guard let repo else { return }
        hooksWorkspace.busy = true
        Task.detached(priority: .userInitiated) {
            do {
                try operation(repo)
                await MainActor.run {
                    self.hooksWorkspace.busy = false
                    self.hooksWorkspace.feedback = successDetail
                    self.feedbackCenter.success(title, detail: successDetail)
                    self.reloadGitHooks()
                    if let selected = self.hooksWorkspace.selection {
                        self.selectGitHook(selected)
                    }
                }
            } catch {
                await MainActor.run {
                    self.hooksWorkspace.busy = false
                    self.hooksWorkspace.feedback = errorMessage(error)
                    self.feedbackCenter.error(title, detail: errorMessage(error))
                }
            }
        }
    }

    func saveGitHookDraft() {
        guard let name = hooksWorkspace.selection else { return }
        let content = hooksWorkspace.draft
        runHookAction("Save git hook", successDetail: name) { repo in
            _ = try repo.saveGitHook(name: name, content: content)
        }
    }

    func revertGitHookDraft() {
        guard let contents = hooksWorkspace.contents else { return }
        hooksWorkspace.draft = contents.content
    }

    func toggleGitHookEnabled(_ hook: GitHookInfo) {
        let enable = hook.state != .enabled
        runHookAction(
            enable ? "Enable git hook" : "Disable git hook",
            successDetail: hook.name
        ) { repo in
            _ = try repo.setGitHookEnabled(name: hook.name, enabled: enable)
        }
    }

    func installGitHookSample(_ name: String) {
        runHookAction("Install git hook sample", successDetail: name) { repo in
            _ = try repo.installGitHookSample(name: name)
        }
    }

    func deleteGitHook(_ name: String) {
        runHookAction("Delete git hook", successDetail: name) { repo in
            try repo.deleteGitHook(name: name)
        }
        if hooksWorkspace.selection == name {
            hooksWorkspace.selection = nil
            hooksWorkspace.contents = nil
            hooksWorkspace.draft = ""
        }
    }
}
