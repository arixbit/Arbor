import Foundation
import SwiftUI

/// 项目路径、仓库与主窗口导航状态。
@MainActor
final class ProjectWorkspaceState: ObservableObject {
    @Published var path: String?
    @Published var repository: Repository?
    @Published var inputPath: String = ""
    @Published var toolWindowMode: ToolWindowMode = .commit
    @Published var pendingPath: String?
    /// IntelliJ 的 `$Delete` 在 VFS 删除前会先确认；这里保存待确认的路径集合，
    /// 确认对话框由主内容区呈现。
    @Published var pendingDeletePaths: [String] = []
    @Published var showSwitchAlert = false
    @Published var showSearchEverywhere = false
    @Published var searchQuery = ""
    @Published var feedbackDetailMessage: FeedbackMessage?

    init(path: String?, inputPath: String, toolWindowMode: ToolWindowMode) {
        self.path = path
        self.inputPath = inputPath
        self.toolWindowMode = toolWindowMode
    }
}
