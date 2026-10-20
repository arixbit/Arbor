import Foundation
import SwiftUI

/// 子模块列表、输入、反馈与独立日志预览。
@MainActor
final class SubmoduleWorkspaceState: ObservableObject {
    @Published var url: String = ""
    @Published var path: String = ""
    @Published var submodules: [SubmoduleInfo] = []
    @Published var feedback: String?
    @Published var showLog = false
    @Published var logPath = ""
    @Published var logEntries: [CommitInfo] = []
    @Published var logError: String?
}
