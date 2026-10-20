import Foundation
import SwiftUI

/// Log 的运行期数据状态：Git Log Command 输出、提交签名列、多 root 聚合视图。
///
/// 这里放的是「日志视图自己加载出来的数据」，和用户偏好（列宽、是否显示
/// 作者列等 `@AppStorage` 项）分开：偏好项必须留在 `@AppStorage` 里才能自动
/// 持久化，数据项才适合收敛进模型。
///
/// 并发约定：`commandGeneration` / `signatureGeneration` 是过期请求的丢弃依据，
/// 后台任务回调前必须和当前值比对；`aggregate*` 字典按 root path 作 key。
@MainActor
final class LogRuntimeState: ObservableObject {
    // MARK: - Git Log Command

    @Published var commandEntries: [CommitInfo] = []
    @Published var commandIsAggregate = false
    @Published var commandFilter = ""
    @Published var commandError: String?
    @Published var commandGeneration = 0
    @Published var commandTask: Task<Void, Never>?
    @Published var isLoadingCommand = false
    @Published var hasMoreCommand = true

    // MARK: - 提交签名列

    @Published var signatureLoadTask: Task<Void, Never>?
    @Published var signatureGeneration = 0
    @Published var signatureStatuses: [String: CommitSignatureInfo] = [:]
    @Published var signatureLoadingIDs: Set<String> = []
    @Published var signatureFailedIDs: Set<String> = []

    // MARK: - 多 root 聚合

    @Published var activeBranches: [BranchInfo] = []
    @Published var activeRemoteBranches: [RemoteBranchInfo] = []
    @Published var activeRemotes: [RemoteInfo] = []
    @Published var aggregateBranchFilters: [LogRootBranchFilter] = []
    @Published var aggregateRevisionRanges: [LogRootRevisionRange] = []
    @Published var aggregateRootPaths: Set<String> = []
    @Published var aggregateRepositories: [String: Repository] = [:]
    @Published var aggregateLoadedCounts: [String: Int] = [:]
    @Published var aggregatePageCursors: [String: String] = [:]

    // MARK: - 图命令与排序

    @Published var graphCommand: LinearBekGraphCommand?
    @Published var sortModeRaw = LogGraphSortChoice.byCommitDate.rawValue

    /// 外部日志窗口在 `init` 阶段就要带上初始 root 与仓库句柄，因此在
    /// 构造时注入；普通窗口用默认值即可。
    init(
        aggregateRootPaths: Set<String> = [],
        aggregateRepositories: [String: Repository] = [:]
    ) {
        self.aggregateRootPaths = aggregateRootPaths
        self.aggregateRepositories = aggregateRepositories
    }
}
