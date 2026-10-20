import Foundation
import SwiftUI

/// 分支清理窗口与 Find Merged 对话框的请求、扫描和报告状态。
/// windowGeneration 与 generation 分别隔离两个入口的过期结果。
@MainActor
final class BranchCleanupState: ObservableObject {
    @Published var windowGeneration = 0
    @Published var showFindMergedDialog = false
    @Published var roots: [BranchCleanupRoot] = []
    @Published var targetBranch = ""
    @Published var prefix = ""
    @Published var isRunning = false
    @Published var hasCalculated = false
    @Published var summary: FindMergedScanSummary?
    @Published var generation = 0
    @Published var task: Task<Void, Never>?
    @Published var reportID: String?
    @Published var reportText = ""
    @Published var showReport = false
}
