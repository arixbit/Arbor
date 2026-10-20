import Foundation
import SwiftUI

/// Tag 工作区状态：已加载的 tag 列表、创建对话框输入、删除恢复上下文。
///
/// `repositoryOverride` 存在的原因是：tag 对话框可以对某个 root 打开，而
/// 当前窗口的 `repo` 可能指向另一个 root，创建时必须用被选中的那个句柄。
@MainActor
final class TagWorkspaceState: ObservableObject {
    @Published var tags: [TagInfo] = []

    // 创建 / 推送对话框输入
    @Published var showCreateDialog = false
    @Published var showRemoteTagsDialog = false
    @Published var showMultiRootRemoteTagsDialog = false
    @Published var name = ""
    @Published var at = ""
    @Published var message = ""
    @Published var signKey = ""
    @Published var annotated = false
    @Published var force = false
    @Published var feedback: String?

    /// 当前对话框操作的仓库；nil 表示跟随窗口的默认仓库。
    @Published var repositoryOverride: Repository?

    /// 删除操作的部分成功恢复上下文。
    @Published var deleteRecovery: TagDeleteRecoveryContext?
    @Published var multiRootDeleteRecovery: MultiRootTagDeleteRecoveryContext?
    @Published var showMultiRootDeleteDialog = false
    @Published var multiRootDeleteName = ""
    @Published var multiRootDeleteSelectedRootPaths: Set<String> = []
}
