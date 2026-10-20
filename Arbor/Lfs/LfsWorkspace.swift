import SwiftUI

/// LFS 面板的状态与动作。所有 `git-lfs` 调用都放在后台线程，回到主线程
/// 再更新面板状态，和其它 Git 操作保持同一套刷新/反馈约定。
extension ContentView {
    func presentLfsPanel() {
        lfsWorkspace.showPanel = true
        reloadLfsState()
    }

    /// 用 `.gitattributes` 的 `filter=lfs` 命中情况 + 工作区 pointer 检测，给
    /// Changes 列表打 LFS 标记。每次状态刷新跑一次 `git check-attr`，不读文件内容。
    func refreshLfsPathMarkers() {
        guard let repo else { return }
        let paths = repositoryStatus.entries.map(\.path)
        guard !paths.isEmpty else {
            lfsWorkspace.trackedPaths = []
            lfsWorkspace.pointerPaths = []
            return
        }
        Task.detached(priority: .utility) {
            let states = (try? repo.lfsPathStates(paths: paths)) ?? []
            await MainActor.run {
                guard self.projectWorkspace.repository === repo else { return }
                self.lfsWorkspace.trackedPaths = Set(states.filter(\.tracked).map(\.path))
                self.lfsWorkspace.pointerPaths = Set(states.filter(\.pointer).map(\.path))
            }
        }
    }

    func reloadLfsState() {
        guard let repo else { return }
        let allRevisions = lfsWorkspace.showAllRevisions
        lfsWorkspace.busy = true
        Task.detached(priority: .userInitiated) {
            let capability = repo.lfsCapability()
            let patterns = (try? repo.lfsTrackedPatterns()) ?? []
            let files = (try? repo.lfsFiles(allRevisions: allRevisions)) ?? []
            let hooks = repo.lfsHookState()
            await MainActor.run {
                self.lfsWorkspace.capability = capability
                self.lfsWorkspace.patterns = patterns
                self.lfsWorkspace.files = files
                self.lfsWorkspace.hooks = hooks
                self.lfsWorkspace.busy = false
            }
        }
    }

    private func runLfsAction(
        _ title: String,
        successDetail: String? = nil,
        operation: @escaping (Repository, GitCancelHandle) throws -> LfsCommandResult
    ) {
        guard let repo else { return }
        lfsWorkspace.busy = true
        lfsWorkspace.feedback = nil
        let handle = GitCancelHandle()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try operation(repo, handle)
                await MainActor.run {
                    self.lfsWorkspace.busy = false
                    var detail = successDetail ?? (result.output.isEmpty ? nil : result.output)
                    if result.installedFilters {
                        let note = "该仓库之前没有 filter 配置，已执行 git lfs install --local。"
                        detail = detail.map { "\($0)\n\(note)" } ?? note
                    }
                    self.lfsWorkspace.feedback = detail
                    self.feedbackCenter.success(title, detail: detail)
                    self.reloadLfsState()
                }
            } catch {
                await MainActor.run {
                    self.lfsWorkspace.busy = false
                    self.lfsWorkspace.feedback = errorMessage(error)
                    self.feedbackCenter.error(title, detail: errorMessage(error))
                }
            }
        }
    }

    func lfsTrackCurrentInput() {
        let pattern = lfsWorkspace.trackInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        runLfsAction("Track LFS pattern", successDetail: pattern) { repo, _ in
            try repo.lfsTrack(patterns: [pattern])
        }
        lfsWorkspace.trackInput = ""
    }

    func lfsUntrack(_ pattern: String) {
        runLfsAction("Untrack LFS pattern", successDetail: pattern) { repo, _ in
            try repo.lfsUntrack(patterns: [pattern])
        }
    }

    func lfsInstallHooks() {
        runLfsAction("Install Git LFS") { repo, _ in
            try repo.lfsInstall()
        }
    }

    func lfsUninstallHooks() {
        runLfsAction("Uninstall Git LFS") { repo, _ in
            try repo.lfsUninstall()
        }
    }

    private var lfsRemote: String? {
        let name = lfsWorkspace.remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func lfsFetchObjects() {
        let remote = lfsRemote
        let paths = Array(lfsWorkspace.selectedPaths)
        runLfsAction("Fetch LFS objects") { repo, handle in
            try repo.lfsFetch(remote: remote, allRevisions: false, paths: paths, cancel: handle)
        }
    }

    func lfsPullObjects() {
        let remote = lfsRemote
        let paths = Array(lfsWorkspace.selectedPaths)
        runLfsAction("Pull LFS objects") { repo, handle in
            try repo.lfsPull(remote: remote, paths: paths, cancel: handle)
        }
    }

    func lfsPushObjects() {
        let remote = lfsRemote
        runLfsAction("Push LFS objects") { repo, handle in
            try repo.lfsPush(remote: remote, allRevisions: true, cancel: handle)
        }
    }

    func lfsPruneObjects() {
        runLfsAction("Prune LFS objects") { repo, handle in
            try repo.lfsPrune(cancel: handle)
        }
    }

    /// 把未下载的 LFS 文件还原成真实内容。没有显式选区时，整仓库 checkout。
    func lfsCheckoutPointers() {
        let paths = Array(lfsWorkspace.selectedPaths)
        runLfsAction("Checkout LFS files") { repo, handle in
            try repo.lfsCheckout(paths: paths, cancel: handle)
        }
    }
}
