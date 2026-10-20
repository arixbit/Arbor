import Foundation
import SwiftUI

/// Stash / Unstash 工作页的列表与视图状态。
///
/// 这里集中保存列表缓存和 UI 状态（对话框开关、当前选择、预览内容），
/// 所以从 `ContentView` 的 620 条 `@State` 里抽出来单独持有：
///
/// - `ContentView` 只保留一个 `@StateObject`，新增 stash 交互不必再往主视图里
///   加字段；
/// - 面板与对话框继续用 `@Binding` 接收具体字段，测试和预览不需要构造整个
///   工作区上下文；
/// - 预览/比较的「请求身份」也放在这里，切换 stash 时不会串到上一个请求。
@MainActor
final class StashWorkspaceState: ObservableObject {
    @Published var stashes: [StashInfo] = []

    // MARK: - 创建 stash

    @Published var showCreateDialog = false
    @Published var rootPath: String?
    @Published var currentBranch = ""
    @Published var rootLoading = false
    @Published var message = ""
    @Published var keepIndex = false

    // MARK: - 按文件创建 stash

    @Published var showFilesDialog = false
    @Published var filesInitialPaths: Set<String> = []
    @Published var filesMessage = ""

    // MARK: - 恢复 stash

    @Published var showUnstashDialog = false
    @Published var unstashRootPath: String?
    @Published var unstashStashes: [StashInfo] = []
    @Published var unstashCurrentBranch = ""
    @Published var unstashRootLoading = false
    @Published var showUnstashAsDialog = false
    @Published var unstashAsStashID: String?

    // MARK: - 预览与 diff

    @Published var previewStashID: String?
    @Published var previewText: String?
    @Published var showPreview = false
    @Published var diffStashID: String?
    @Published var diffText: String?
    @Published var diffRootPath: String?
    @Published var showDiff = false

    /// 打开创建对话框前重置上次的输入，避免上次的 message 带到新目标上。
    func beginCreate(rootPath: String?, currentBranch: String) {
        self.rootPath = rootPath
        self.currentBranch = currentBranch
        rootLoading = false
        message = ""
        keepIndex = false
        showCreateDialog = true
    }

    /// 打开恢复对话框。
    func beginUnstash(rootPath: String?, stashes: [StashInfo], currentBranch: String) {
        unstashRootPath = rootPath
        unstashStashes = stashes
        unstashCurrentBranch = currentBranch
        unstashRootLoading = false
        showUnstashDialog = true
    }

    /// 关掉 stash 预览，并清掉请求身份，避免迟到结果覆盖新的选择。
    func clearPreview() {
        previewStashID = nil
        previewText = nil
        showPreview = false
    }

    /// 关掉 stash diff，并按 root 判断是否属于当前目标。
    func clearDiff(rootPath: String?) {
        guard diffRootPath == rootPath else { return }
        showDiff = false
        diffText = nil
        diffStashID = nil
        diffRootPath = nil
    }
}
