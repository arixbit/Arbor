import Foundation
import SwiftUI

/// Log 左侧分支面板的状态：分组方式、选中行为，以及「只看我的分支」的数据。
///
/// 这些是面板级偏好 + 派生数据，和日志列表本身（`LogListState`）分开：面板
/// 可以独立重算「我的分支」而不影响日志查询。
@MainActor
final class LogBranchesPanelState: ObservableObject {
    @Published var groupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    @Published var groupByRepository = GitBranchesPopupSettings.defaultGroupByRepository
    @Published var selectionActionRaw = LogBranchSelectionAction.navigate.rawValue
    @Published var showOnlyMy = false
    @Published var myBranchIDs: Set<String> = []
    @Published var showMyTask: Task<Void, Never>?

    /// 面板偏好按项目持久化，值由 `ContentView.init` 读出来注入。
    init(
        groupByDirectory: Bool = GitBranchesPopupSettings.defaultGroupByDirectory,
        groupByRepository: Bool = GitBranchesPopupSettings.defaultGroupByRepository,
        selectionActionRaw: String = LogBranchSelectionAction.navigate.rawValue
    ) {
        self.groupByDirectory = groupByDirectory
        self.groupByRepository = groupByRepository
        self.selectionActionRaw = selectionActionRaw
    }
}
