import Foundation
import SwiftUI

/// Log 工作区的选中、详情、tab 与提交导航状态。
///
/// 与 `LogListState`（列表与过滤）、`LogRuntimeState`（加载出来的数据）分开：
/// 这里放的是「用户当前在看什么」。
///
/// tab 生命周期约定（外部日志窗口）：
/// - 外部窗口打开时，`ContentView.init` 先从持久化恢复 tab 列表并调用
///   `ExternalLogManager.registerUI(id)`，然后把同一份值注入本对象的 init；
/// - `appendLogTabAndLoad` 先 register 再 append，register 失败就不加 tab；
/// - `closeLogTab` 先 `disposeUI(id)` 再移除，二者顺序不能反，否则窗口关闭后
///   管理器里会留下注册项；
/// - 本对象只在主 actor 上被修改，后台任务必须回到 `MainActor.run` 再写。
@MainActor
final class LogSelectionState: ObservableObject {
    // MARK: - 选中

    @Published var selection: String?
    /// Cmd/Shift 多选，工具栏与批量操作共用。
    @Published var selectedIDs: Set<String> = []

    // MARK: - 详情

    @Published var inspectorPresented = false
    @Published var detailCommit: CommitInfo?
    @Published var detailLoadTask: Task<Void, Never>?

    // MARK: - Tab

    @Published var tabs: [LogTabDescriptor]
    @Published var activeTabID: UUID?

    // MARK: - 父/子提交导航

    @Published var pendingNavigationCommits: [CommitInfo] = []
    @Published var isNavigationChoicePresented = false
    @Published var navigationChoosesParent = false
    @Published var pendingNavigationSelection: String?
    @Published var pendingNavigationGeneration: Int?

    // MARK: - Patch 恢复通知去重

    @Published var applyRecoveryNotificationFingerprints: [String: String] = [:]

    /// tab 列表由外部注入：外部日志窗口需要从持久化状态恢复，普通窗口用默认
    /// 单个 tab。
    init(
        tabs: [LogTabDescriptor] = [LogTabDescriptor()],
        activeTabID: UUID? = nil
    ) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}
