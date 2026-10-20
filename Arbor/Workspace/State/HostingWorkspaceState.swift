import Foundation
import SwiftUI

/// 托管平台设置、身份提示与代码评审入口。
@MainActor
final class HostingWorkspaceState: ObservableObject {
    @Published var showHostingSettings = false
    @Published var showHostingHub = false
    @Published var showHostingAuthPrompt = false
    @Published var reviewCommentCommit: CommitInfo?
    @Published var reviewCommentRepository: HostingRepository?
    @Published var showReviewComment = false
}
