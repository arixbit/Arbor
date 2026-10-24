import Foundation
import SwiftUI

/// Log 列表与过滤的工作区状态。
///
/// 这是 Phase B 的第二块：`ContentView` 里和「日志列表 + 过滤条件」相关的
/// 32 条 `@State` 收敛成一个对象。视图仍然通过参数/`@Binding` 拿具体值，
/// 只有 `ContentView` 与它的扩展直接读写这个对象。
///
/// 约定：
/// - 过滤输入是草稿态，真正触发查询的是各 `applyLogFilter*` 入口，模型只负责
///   保存当前选择；
/// - `generation` 与两个 `Task` 负责取消过期请求，改动这里要同步检查
///   `logGeneration` 的自增点；
/// - `activeRepo` 持有当前日志来源仓库句柄，切换 root 时必须和
///   `activeRootPath` 一起更新。
@MainActor
final class LogListState: ObservableObject {
    // MARK: - 过滤条件

    /// 「Go to Revision」弹窗的输入与开关。
    @Published var revisionInput = ""
    @Published var revisionFilterPresented = false

    @Published var authorFilter = ""
    @Published var messageFilter = ""
    @Published var messageRegex = false
    @Published var messageMatchCase = false
    @Published var since = ""
    @Published var until = ""
    @Published var advancedFiltersPresented = false
    @Published var dateFiltersPresented = false

    // MARK: - 路径过滤

    @Published var pathFilter = ""
    @Published var pathFilterSelections: [LogPathFilterSelection] = []
    @Published var visibleRootPathsRaw = ""
    @Published var pathsEditorPresented = false
    @Published var pathsEditorText = ""
    @Published var pathsTreeChooserPresented = false
    @Published var pathsTreeChooserRoots: [LogPathChooserRoot] = []
    @Published var pathsTreeChooserSelections: Set<LogPathFilterSelection> = []

    // MARK: - 列表与分页

    @Published var entries: [CommitInfo] = []
    @Published var hasMore = true
    @Published var pageCursor: String?
    @Published var isLoadingMore = false
    @Published var isLoading = false
    /// 当前显示的是磁盘缓存快照，真实加载还在进行。
    @Published var isShowingCachedSnapshot = false
    @Published var error: String?

    // MARK: - 请求生命周期

    @Published var generation = 0
    @Published var loadTask: Task<Void, Never>?
    @Published var refreshTask: Task<Void, Never>?

    // MARK: - 呈现方式

    @Published var follow = false
    @Published var viewMode: LogViewMode = .graph
    @Published var startRevision = ""
    @Published var startRevisions: Set<String> = []

    // MARK: - 当前 root

    @Published var activeRootPath: String?
    @Published var activeRepo: Repository?
}
