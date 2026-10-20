import Foundation
import SwiftUI

/// Log 里的提交改写对话框（Reword / Squash）状态。
///
/// 两者都作用在选中提交上，打开前由调用方填好初始值；`rootRebase` 记录这次
/// 改写是否需要 --root 变基，撤销动作依赖它。
@MainActor
final class LogRewriteState: ObservableObject {
    @Published var showRewordDialog = false
    @Published var rewordCommit: CommitInfo?
    @Published var rewordMessage = ""
    @Published var rewordUsesRootRebase = false

    @Published var showSquashDialog = false
    @Published var squashMessage = ""
    @Published var squashIndexes: [Int] = []
    @Published var squashSummaries: [String] = []
}
