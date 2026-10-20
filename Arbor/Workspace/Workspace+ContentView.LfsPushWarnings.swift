import SwiftUI
import AppKit
import UniformTypeIdentifiers



/// push 完成后确认 LFS 对象这次是否真的会上传：
/// - 装了 pre-push hook 时 `git-lfs` 自己会上传，不必提示；
/// - 仓库有 LFS 跟踪规则但没有 hook（或本次显式跳过 hooks）时，代码推上去了、
///   对象却没上传，后续 clone 会拿到 pointer，必须明确告警。
func lfsPushCoverageWarning(repo: Repository, skipHooks: Bool) -> String? {
    guard repo.lfsCapability().installed else { return nil }
    let patterns = (try? repo.lfsTrackedPatterns()) ?? []
    guard !patterns.isEmpty else { return nil }
    if skipHooks {
        return "本次 Push 跳过了 Git hooks，Git LFS 对象不会随代码一起上传。"
    }
    guard !repo.lfsHookState().prePush else { return nil }
    return "该仓库没有安装 Git LFS 的 pre-push hook，本次 Push 只上传了代码引用，LFS 对象没有上传。"
}


/// 多 root Push 的 LFS 覆盖检查：逐个成功 root 判断 LFS 对象是否随代码上传。
/// 在后台线程调用（会打开每个 root 的 Repository）。
func lfsPushCoverageWarnings(results: [RootOperationResult], skipHooks: Bool) -> [String] {
    var warnings: [String] = []
    for result in results where result.success && !result.skipped {
        guard let rootRepo = try? openRepository(path: result.rootPath),
              let warning = lfsPushCoverageWarning(repo: rootRepo, skipHooks: skipHooks)
        else { continue }
        let displayName = result.displayName.isEmpty ? result.rootPath : result.displayName
        warnings.append("\(displayName)：\(warning)")
    }
    return warnings
}

extension ContentView {
    /// 把 LFS 覆盖告警合成为一条通知，避免每个 root 刷一遍。
    func publishLfsPushWarnings(_ warnings: [String]) {
        guard !warnings.isEmpty else { return }
        feedbackCenter.warning(
            "Git LFS objects were not uploaded",
            detail: warnings.joined(separator: "\n"),
            nextStep: "在 Git LFS 面板安装 hooks，或手动执行 Push LFS objects。"
        )
    }
}
