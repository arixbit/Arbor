import SwiftUI
import AppKit


struct MultiRootPushContext: Identifiable {
    let id = UUID()
    let rootPath: String
    let repo: Repository
    let remotes: [RemoteInfo]
    let branches: [BranchInfo]
    let commits: [CommitInfo]
    let defaultRemote: String?
    let defaultBranch: String?
    let defaultSourceRevision: String?
    let currentHasUpstream: Bool
    let protectedBranchPatterns: [String]
    let defaultPushTagMode: PushDialogTagMode?
}

struct MultiRootPushRetryContext {
    let rootPaths: [String]
    let recoveryRebase: Bool?
    let recoveryUpdateRootPaths: [String]?
    let tagMode: PushDialogTagMode?
    let skipHooks: Bool
    let force: Bool
    let forceWithLease: Bool
    let viewCommitRanges: [PersistedLogRevisionRange]
    let resultRows: [FeedbackResultRow]
    let targetSelections: [MultiRootPushTargetSelection]

    init(
        rootPaths: [String],
        recoveryRebase: Bool? = nil,
        recoveryUpdateRootPaths: [String]? = nil,
        tagMode: PushDialogTagMode? = nil,
        skipHooks: Bool = false,
        force: Bool = false,
        forceWithLease: Bool = false,
        viewCommitRanges: [PersistedLogRevisionRange] = [],
        resultRows: [FeedbackResultRow] = [],
        targetSelections: [MultiRootPushTargetSelection] = []
    ) {
        self.rootPaths = rootPaths
        self.recoveryRebase = recoveryRebase
        self.recoveryUpdateRootPaths = recoveryUpdateRootPaths
        self.tagMode = tagMode
        self.skipHooks = skipHooks
        self.force = force
        self.forceWithLease = forceWithLease
        self.viewCommitRanges = viewCommitRanges
        self.resultRows = resultRows
        self.targetSelections = targetSelections
    }
}
