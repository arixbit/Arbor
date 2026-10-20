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
