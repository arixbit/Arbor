import SwiftUI

/// IntelliJ 对照：`GitShallowRepositoryCheck`（backend ProjectActivity +
/// `RunOnceUtil.runOnceForProject`）。
///
/// 单仓库项目打开时检查 shallow clone；命中时由宿主窗口发布一次重要信息级
/// 通知，引导执行既有的 Fetch Full History（Unshallow）动作。多 root 项目、
/// 非 shallow 仓库、无法解析默认 fetch remote 的仓库以及打开失败的仓库保持
/// 静默，不产生任何用户可见反馈，也不写诊断之外的状态。
enum GitShallowRepositoryCheckOutcome: Equatable {
    /// 按对照语义静默：多 root、非 shallow、无默认 fetch remote 或仓库打开失败。
    case silent
    /// shallow 且存在默认 fetch remote：应提示补全历史。
    case suggestUnshallow(rootPath: String, remote: String)
}

/// 纯决策函数，逐条对应 fork 的条件分支，便于单测覆盖。
/// `rootCount` 对应 `repositories.singleOrNull()` 的仓库数：只有恰好一个
/// 仓库时才检查。
func gitShallowRepositoryCheckDecision(
    rootPath: String?,
    rootCount: Int,
    isShallow: Bool,
    defaultFetchRemote: String?
) -> GitShallowRepositoryCheckOutcome {
    guard rootCount == 1, let rootPath, isShallow, let defaultFetchRemote else {
        return .silent
    }
    return .suggestUnshallow(rootPath: rootPath, remote: defaultFetchRemote)
}

/// `RunOnceUtil.runOnceForProject` 的等价物：每个项目只执行一次检查块。
/// fork 在 ProjectActivity 内先按仓库数短路，再进入 runOnce，所以多 root
/// 项目不会留下标记；这里保持同一顺序。
enum GitShallowRepositoryRunOnce {
    static func key(projectPath: String) -> String {
        gitProjectSettingsKey("arbor.git.shallowCheck.runOnce.v1.", for: projectPath)
    }

    static func hasRun(defaults: UserDefaults, projectPath: String) -> Bool {
        defaults.bool(forKey: key(projectPath: projectPath))
    }

    static func markRun(defaults: UserDefaults, projectPath: String) {
        defaults.set(true, forKey: key(projectPath: projectPath))
    }
}

struct GitShallowRepositoryCheck: View {
    let rootPaths: [String]
    let projectPath: String?
    var defaults: UserDefaults = .standard
    let onSuggestion: (String, String) -> Void

    init(
        rootPaths: [String],
        projectPath: String?,
        defaults: UserDefaults = .standard,
        onSuggestion: @escaping (String, String) -> Void
    ) {
        self.rootPaths = rootPaths
        self.projectPath = projectPath
        self.defaults = defaults
        self.onSuggestion = onSuggestion
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: "\(projectPath ?? "")|\(rootPaths.joined(separator: "|"))") {
                await evaluate()
            }
    }

    private func evaluate() async {
        guard let projectPath else { return }
        // fork: repositories.singleOrNull() ?: return —— 多 root 项目在
        // 进入 RunOnce 之前就返回，不留下已检查标记。
        guard rootPaths.count == 1, let rootPath = rootPaths.first else { return }
        guard !GitShallowRepositoryRunOnce.hasRun(defaults: defaults, projectPath: projectPath) else {
            return
        }
        // RunOnceUtil 语义：检查块只执行一次，无论结果如何都落标记。
        GitShallowRepositoryRunOnce.markRun(defaults: defaults, projectPath: projectPath)

        let outcome = await Task.detached(priority: .utility) { () -> GitShallowRepositoryCheckOutcome in
            let repo: Repository
            do {
                repo = try openRepository(path: rootPath)
            } catch {
                return .silent
            }
            guard repo.isShallow() else { return .silent }
            let remotes = (try? repo.remoteList()) ?? []
            let remote = defaultFetchRemoteName(
                preferredRemote: nil,
                availableRemoteNames: remotes.map(\.name)
            )
            guard let remote else { return .silent }
            return .suggestUnshallow(rootPath: rootPath, remote: remote)
        }.value

        guard case let .suggestUnshallow(rootPath, remote) = outcome else { return }
        DiagnosticsLogger.shared.record(
            operation: "shallow-check",
            repositoryPath: rootPath,
            code: "suggest-unshallow"
        )
        onSuggestion(rootPath, remote)
    }
}
