import Foundation
import SwiftUI

/// 工作区状态快照、刷新协调与暂存模型。
@MainActor
final class RepositoryStatusState: ObservableObject {
    @Published var entries: [FileEntry] = []
    @Published var changeLists: [ChangeListInfo] = []
    @Published var refreshGate = RepositoryRefreshGate()
    @Published var changeBatch = RepositoryChangeBatch()
    @Published var externalVCSActionManager = RepositoryExternalVCSActionManager()
    @Published var dirtyScopeManager = RepositoryDirtyScopeManager()
    @Published var dirtyFileManager = RepositoryDirtyFileManager()
    @Published var changeDeliveryTask: Task<Void, Never>?
    @Published var ignoredRules: [IgnoreRuleInfo] = []
    @Published var headId: String?
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var isShowingCachedStatusSnapshot = false
    /// IDX-001 三层 staging 模型（二进制徽标/忽略入口数据源）。
    @Published var stagingModel: StagingModel?
    /// index tracker：外部 Git 修改 index 后提示刷新。
    @Published var lastIndexRevision: IndexRevision?
    @Published var isShallowRepository = false
}
