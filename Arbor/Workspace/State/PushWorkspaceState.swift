import Foundation
import SwiftUI

/// 推送选项、目标引用与多 root 重试上下文。
@MainActor
final class PushWorkspaceState: ObservableObject {
    @Published var force = false
    @Published var showDialog = false
    @Published var showMultiRootPushOptions = false
    @Published var multiRootPushOptionsRootPaths: [String]?
    @Published var multiRootPushOptionsFromCommit = false
    @Published var multiRootPushContext: MultiRootPushContext?
    @Published var addCommitsToRemoteBranchContext: AddCommitsToRemoteBranchContext?
    @Published var dialogMode: PushDialogMode = .push
    @Published var dialogRefspec: String?
    @Published var dialogRemote: String?
    @Published var dialogBranch: String?
    @Published var dialogSourceRevision: String?
    @Published var feedback: String?
    @Published var multiRootPushRetryContext: MultiRootPushRetryContext?
}
