import Foundation
import SwiftUI

/// 单 root 与多 root 提交草稿、提交选项和后续动作。
@MainActor
final class CommitWorkspaceState: ObservableObject, InlineFeedbackReporting {
    @Published var message: String = ""
    /// Keep the Commit/Stash choice when opening or closing the Project panel
    /// rebuilds the tool window's SwiftUI view.
    @Published var selectedToolTab: RebasedCommitWorkspace.Tab = .commit
    /// The Commit view's checkboxes select paths independently of Git staging.
    /// A new repository starts with nothing selected, as in the Changes view.
    @Published private(set) var includedPathsByRoot: [String: Set<String>] = [:]
    @Published var feedback: String?
    @Published var feedbackTone: InlineFeedbackTone = .failure
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

    func includedPaths(for root: String?) -> Set<String> {
        guard let root else { return [] }
        return includedPathsByRoot[URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path] ?? []
    }

    func setIncluded(_ included: Bool, path: String, in root: String?) {
        guard let root else { return }
        let key = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        if included {
            includedPathsByRoot[key, default: []].insert(path)
        } else {
            includedPathsByRoot[key, default: []].remove(path)
        }
    }

    func retainChangedPaths(_ paths: Set<String>, in root: String?) {
        guard let root else { return }
        let key = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        includedPathsByRoot[key]?.formIntersection(paths)
    }
}
