import SwiftUI

/// LFS 面板的状态与动作。所有 `git-lfs` 调用都放在后台线程，回到主线程
/// 再更新面板状态，和其它 Git 操作保持同一套刷新/反馈约定。
extension ContentView {
    func presentLfsPanel() {
        showLfsPanel = true
        reloadLfsState()
    }

    /// 用 `.gitattributes` 的 `filter=lfs` 命中情况 + 工作区 pointer 检测，给
    /// Changes 列表打 LFS 标记。每次状态刷新跑一次 `git check-attr`，不读文件内容。
    func refreshLfsPathMarkers() {
        guard let repo else { return }
        let paths = entries.map(\.path)
        guard !paths.isEmpty else {
            lfsTrackedPaths = []
            lfsPointerPaths = []
            return
        }
        Task.detached(priority: .utility) {
            let states = (try? repo.lfsPathStates(paths: paths)) ?? []
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.lfsTrackedPaths = Set(states.filter(\.tracked).map(\.path))
                self.lfsPointerPaths = Set(states.filter(\.pointer).map(\.path))
            }
        }
    }

    func reloadLfsState() {
        guard let repo else { return }
        let allRevisions = lfsShowAllRevisions
        lfsBusy = true
        Task.detached(priority: .userInitiated) {
            let capability = repo.lfsCapability()
            let patterns = (try? repo.lfsTrackedPatterns()) ?? []
            let files = (try? repo.lfsFiles(allRevisions: allRevisions)) ?? []
            let hooks = repo.lfsHookState()
            await MainActor.run {
                self.lfsCapability = capability
                self.lfsPatterns = patterns
                self.lfsFiles = files
                self.lfsHooks = hooks
                self.lfsBusy = false
            }
        }
    }

    private func runLfsAction(
        _ title: String,
        successDetail: String? = nil,
        operation: @escaping (Repository, GitCancelHandle) throws -> LfsCommandResult
    ) {
        guard let repo else { return }
        lfsBusy = true
        lfsFeedback = nil
        let handle = GitCancelHandle()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try operation(repo, handle)
                await MainActor.run {
                    self.lfsBusy = false
                    var detail = successDetail ?? (result.output.isEmpty ? nil : result.output)
                    if result.installedFilters {
                        let note = "该仓库之前没有 filter 配置，已执行 git lfs install --local。"
                        detail = detail.map { "\($0)\n\(note)" } ?? note
                    }
                    self.lfsFeedback = detail
                    self.feedbackCenter.success(title, detail: detail)
                    self.reloadLfsState()
                }
            } catch {
                await MainActor.run {
                    self.lfsBusy = false
                    self.lfsFeedback = errorMessage(error)
                    self.feedbackCenter.error(title, detail: errorMessage(error))
                }
            }
        }
    }

    func lfsTrackCurrentInput() {
        let pattern = lfsTrackInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        runLfsAction("Track LFS pattern", successDetail: pattern) { repo, _ in
            try repo.lfsTrack(patterns: [pattern])
        }
        lfsTrackInput = ""
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
        let name = lfsRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func lfsFetchObjects() {
        let remote = lfsRemote
        runLfsAction("Fetch LFS objects") { repo, handle in
            try repo.lfsFetch(remote: remote, allRevisions: false, cancel: handle)
        }
    }

    func lfsPullObjects() {
        let remote = lfsRemote
        runLfsAction("Pull LFS objects") { repo, handle in
            try repo.lfsPull(remote: remote, cancel: handle)
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
        let paths = Array(lfsSelectedPaths)
        runLfsAction("Checkout LFS files") { repo, handle in
            try repo.lfsCheckout(paths: paths, cancel: handle)
        }
    }
}
