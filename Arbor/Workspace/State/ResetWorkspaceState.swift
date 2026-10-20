import Foundation
import SwiftUI

/// 选中提交和指定 root 的 HEAD Reset 对话框。
@MainActor
final class ResetWorkspaceState: ObservableObject {
    @Published var showDialog = false
    @Published var targetCommit: CommitInfo?
    @Published var targetCommits: [CommitInfo] = []
    @Published var mode: ResetMode = .mixed
    @Published var showHeadDialog = false
    @Published var headRootPath = ""
    @Published var headTarget = "HEAD"
    @Published var headMode: ResetMode = .mixed
}
