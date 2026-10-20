import Foundation
import SwiftUI

/// 单 root 与多 root 提交草稿、提交选项和后续动作。
@MainActor
final class CommitWorkspaceState: ObservableObject {
    @Published var message: String = ""
    @Published var feedback: String?
    @Published var amendMode = false
    @Published var recentMessages: [String] = []
    @Published var skipHooks = false
    @Published var beforeCommitCommands: [BeforeCommitCommand] = []
    @Published var showBeforeCommitSettings = false
    @Published var showMultiRootDialog = false
    @Published var multiRootMessage = ""
    @Published var multiRootRecentMessages: [String] = []
    @Published var multiRootAmendMode = false
    @Published var multiRootSkipHooks = false
    @Published var multiRootAuthorName = ""
    @Published var multiRootAuthorEmail = ""
    @Published var multiRootCommitterName = ""
    @Published var multiRootCommitterEmail = ""
    @Published var multiRootSignOff = false
    @Published var multiRootCoAuthors = ""
    @Published var multiRootSelectedPaths: [MultiRootChangeSelection]?
    /// IntelliJ's Commit and Push executor commits first and opens the Push
    /// options only after the commit succeeds. Keep that intent out of the
    /// push dialog so a failed commit can never publish anything.
    @Published var pendingCommitAndPush = false
    @Published var uncommitRequest: RebasedUncommitRequest?
}
