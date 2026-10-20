import Foundation
import SwiftUI

/// Pull 对话框的快照、更新方式和请求代际。
@MainActor
final class PullWorkspaceState: ObservableObject {
    @Published var showDialog = false
    @Published var snapshots: [GitRootBranchSnapshot] = []
    @Published var rebase = false
    @Published var generation = 0
}
