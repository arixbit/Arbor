import Foundation

/// A small, Codable action context for operations that may outlive the
/// current process. Unlike a closure, this request can be carried by a
/// native notification or restored operation history and routed to the
/// matching project/repository window.
struct ArborVCSActionRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case restoreShelf
        case restoreShelfPaths
        case deleteDeletedShelfPaths
        case undoShelfDeletion
        case undoShelfDeletions
        case dropShelf
        case showSavedChanges
        case showLogApplyAffectedFiles
        case showOperationDetails
        case restoreApplyLocalChanges
        case resumeRebase
        case retryShelfBatch
        case retryShelfMemberBatch
        case retryShelfLifecycleBatch
        case retryShelfDeletePlan
        case retryLogApply
        case retryExternalVCSAction
        case openGpgAgentSettings
        case openIdentitySettings
        case rollbackMultiRootCheckout
        case rollbackMultiRootBranchCreate
        case keepMultiRootBranchCreatePartial
        case rollbackMultiRootBranchRename
        case keepMultiRootBranchRenamePartial
        case rollbackMultiRootMerge
        case rollbackMultiRootUpdate
        case rollbackSubmoduleUpdate
        case retrySubmoduleOperation
        case undoSubmoduleOperation
        case rollbackMultiRootReset
        case rollbackResetRecovery
        case keepResetRecovery
        case deleteMultiRootMergeBranch
        case restoreDeletedBranches
        case viewDeletedBranchCommits
        case retryMultiRootOperation
        case retryPush
        case retryPushRecovery
        case retryStashBranch
        case multiRootRebaseRecovery
        case operationRecovery
        case autoFetchRecovery
        case showLogRanges
        case showFindMergedReport
        case rewordCommit
        case undoRewordCommit
        case undoUncommit
        case undoRebase
        case undoLogSelectedChanges
    }

    enum MultiRootRetryOperation: String, Codable, Equatable, Sendable {
        case update
        case fetch
        case pullMerge
        case pullRebase
        case push
        case pushRecovery
        case checkoutUpdate
        case commit
        case pushAfterCommit
        case stage
        case unstage
        case stageAll
        case unstageAll
    }

    enum CheckoutUpdateMode: String, Codable, Sendable {
        case normal
        case smart
        case force
    }

    enum MultiRootPushTagMode: String, Codable, Sendable {
        case all
        case currentBranch
    }

    enum MultiRootRebaseRecoveryAction: String, Codable, Sendable {
        case resume
        case retry
        case stageAndRetry
        case openRecovery
        case rollback
        case keepPartial
        case undo
    }

    enum OperationRecoveryAction: String, Codable, Sendable {
        case continueOperation
        case skip
        case abort
        case openRecovery
    }

    enum AutoFetchRecoveryAction: String, Codable, Sendable {
        case fetchAll
        case retryCheck
        case enable
        case doNotAskAgain
    }

    enum SavedChangesKind: String, Codable, Sendable {
        case stash
        case shelf
    }

    enum ShelfBatchOperation: String, Codable, Sendable {
        case apply
        case pop
        case drop
    }

    enum ShelfLifecycleOperation: String, Codable, Sendable {
        case restoreDeleted
        case deleteDeleted
    }

    enum ShelfMemberBatchOperation: String, Codable, Sendable {
        case unshelve
        case unshelveAndRemove
        case unshelveDeleted
        case unshelveDeletedAndRemove
        case drop
        case deleteDeleted
    }

    let kind: Kind
    let projectPath: String?
    let rootPath: String?
    let shelfName: String
    let shelfPaths: [String]?
    let shelfRestoreTimestamp: Int64?
    let shelfRestoreTimestamps: [String: Int64]?
    let savedChangesKind: SavedChangesKind?
    let savedChangesID: String?
    let shelfNames: [String]?
    let shelfBatchOperation: ShelfBatchOperation?
    let shelfBatchTargetName: String?
    let shelfBatchRemoveApplied: Bool?
    let shelfMemberGroups: [PersistedShelfPathGroup]?
    let shelfMemberBatchOperation: ShelfMemberBatchOperation?
    let shelfMemberBatchTargetName: String?
    let shelfDeletePlan: PersistedShelfDeletePlan?
    let shelfLifecycleOperation: ShelfLifecycleOperation?
    let logApplyRecovery: PersistedLogApplyRecovery?
    let externalVCSAction: RepositoryExternalVCSAction?
    let rebaseBranch: String?
    let checkoutReference: String?
    let checkoutTargets: [PersistedMultiRootCheckoutTarget]?
    let multiRootBranchName: String?
    let multiRootBranchCreateRollbackTargets: [PersistedMultiRootBranchCreateTarget]?
    let multiRootBranchRenameOldName: String?
    let multiRootBranchRenameNewName: String?
    let multiRootBranchRenameRollbackTargets: [PersistedMultiRootBranchRenameRollbackTarget]?
    let multiRootMergeBranchName: String?
    let multiRootMergeRollbackTargets: [PersistedMultiRootMergeRollbackTarget]?
    let multiRootMergeRollbackResultRows: [FeedbackResultRow]?
    let multiRootMergeDeleteBranchName: String?
    let multiRootMergeDeleteRootPaths: [String]?
    let branchDeleteRecoveryTargets: [PersistedBranchDeleteRecoveryTarget]?
    let multiRootRetryOperation: MultiRootRetryOperation?
    let multiRootRetryRootPaths: [String]?
    let multiRootRetryPath: String?
    let multiRootRetryChangePaths: [PersistedMultiRootChangePath]?
    let multiRootRetryUpdateRootPaths: [String]?
    let multiRootRetryRebase: Bool?
    let multiRootRetryRebaseRootPaths: [String]?
    let multiRootRetryLogRevisionRanges: [PersistedLogRevisionRange]?
    let multiRootRetryResultRows: [FeedbackResultRow]?
    let multiRootRetryDetach: Bool?
    let multiRootRetryCheckoutMode: CheckoutUpdateMode?
    let multiRootPushTagMode: MultiRootPushTagMode?
    let multiRootPushSkipHooks: Bool?
    let multiRootPushForce: Bool?
    let multiRootPushForceWithLease: Bool?
    let multiRootCommitRetry: PersistedMultiRootCommitRetry?
    let pushRecovery: PersistedPushRecovery?
    let stashBranchRetry: PersistedStashBranchRetry?
    let submoduleRetry: PersistedSubmoduleRetry?
    let submoduleUndo: PersistedSubmoduleUndo?
    let multiRootRebaseRecoveryAction: MultiRootRebaseRecoveryAction?
    let multiRootRebaseSessionID: String?
    let multiRootRebaseRollbackTargets: [PersistedMultiRootRebaseRollbackTarget]?
    let multiRootUpdateRollbackTargets: [PersistedMultiRootUpdateRollbackTarget]?
    let multiRootResetRollbackTargets: [PersistedMultiRootResetRollbackTarget]?
    let resetRecoveryTargets: [PersistedResetRecoveryTarget]?
    let operationRecoveryAction: OperationRecoveryAction?
    let autoFetchRecoveryAction: AutoFetchRecoveryAction?
    let autoFetchRootPaths: [String]?
    let logRevisionRanges: [PersistedLogRevisionRange]?
    let operationNotificationID: String?
    let findMergedReportID: String?
    let rewordCommitID: String?
    let rewordUndo: PersistedRewordUndo?
    let uncommitCommitID: String?
    let uncommitExpectedHead: String?
    let uncommitExpectedBranch: String?
    let rebaseUndoInitialHead: String?
    let rebaseUndoExpectedHead: String?
    let rebaseUndoBranch: String?
    let rebaseUndoProtectionCommit: String?
    let logSelectedChangesUndoInitialHead: String?
    let logSelectedChangesUndoExpectedHead: String?
    let logSelectedChangesUndoBranch: String?

    init(
        kind: Kind,
        projectPath: String?,
        rootPath: String?,
        shelfName: String,
        shelfPaths: [String]? = nil,
        shelfRestoreTimestamp: Int64? = nil,
        shelfRestoreTimestamps: [String: Int64]? = nil,
        savedChangesKind: SavedChangesKind? = nil,
        savedChangesID: String? = nil,
        shelfNames: [String]? = nil,
        shelfBatchOperation: ShelfBatchOperation? = nil,
        shelfBatchTargetName: String? = nil,
        shelfBatchRemoveApplied: Bool? = nil,
        shelfMemberGroups: [PersistedShelfPathGroup]? = nil,
        shelfMemberBatchOperation: ShelfMemberBatchOperation? = nil,
        shelfMemberBatchTargetName: String? = nil,
        shelfDeletePlan: PersistedShelfDeletePlan? = nil,
        shelfLifecycleOperation: ShelfLifecycleOperation? = nil,
        logApplyRecovery: PersistedLogApplyRecovery? = nil,
        externalVCSAction: RepositoryExternalVCSAction? = nil,
        rebaseBranch: String? = nil,
        checkoutReference: String? = nil,
        checkoutTargets: [PersistedMultiRootCheckoutTarget]? = nil,
        multiRootBranchName: String? = nil,
        multiRootBranchCreateRollbackTargets: [PersistedMultiRootBranchCreateTarget]? = nil,
        multiRootBranchRenameOldName: String? = nil,
        multiRootBranchRenameNewName: String? = nil,
        multiRootBranchRenameRollbackTargets: [PersistedMultiRootBranchRenameRollbackTarget]? = nil,
        multiRootMergeBranchName: String? = nil,
        multiRootMergeRollbackTargets: [PersistedMultiRootMergeRollbackTarget]? = nil,
        multiRootMergeRollbackResultRows: [FeedbackResultRow]? = nil,
        multiRootMergeDeleteBranchName: String? = nil,
        multiRootMergeDeleteRootPaths: [String]? = nil,
        branchDeleteRecoveryTargets: [PersistedBranchDeleteRecoveryTarget]? = nil,
        multiRootRetryOperation: MultiRootRetryOperation? = nil,
        multiRootRetryRootPaths: [String]? = nil,
        multiRootRetryPath: String? = nil,
        multiRootRetryChangePaths: [PersistedMultiRootChangePath]? = nil,
        multiRootRetryUpdateRootPaths: [String]? = nil,
        multiRootRetryRebase: Bool? = nil,
        multiRootRetryRebaseRootPaths: [String]? = nil,
        multiRootRetryLogRevisionRanges: [PersistedLogRevisionRange]? = nil,
        multiRootRetryResultRows: [FeedbackResultRow]? = nil,
        multiRootRetryDetach: Bool? = nil,
        multiRootRetryCheckoutMode: CheckoutUpdateMode? = nil,
        multiRootPushTagMode: MultiRootPushTagMode? = nil,
        multiRootPushSkipHooks: Bool? = nil,
        multiRootPushForce: Bool? = nil,
        multiRootPushForceWithLease: Bool? = nil,
        multiRootCommitRetry: PersistedMultiRootCommitRetry? = nil,
        pushRecovery: PersistedPushRecovery? = nil,
        stashBranchRetry: PersistedStashBranchRetry? = nil,
        submoduleRetry: PersistedSubmoduleRetry? = nil,
        submoduleUndo: PersistedSubmoduleUndo? = nil,
        multiRootRebaseRecoveryAction: MultiRootRebaseRecoveryAction? = nil,
        multiRootRebaseSessionID: String? = nil,
        multiRootRebaseRollbackTargets: [PersistedMultiRootRebaseRollbackTarget]? = nil,
        multiRootUpdateRollbackTargets: [PersistedMultiRootUpdateRollbackTarget]? = nil,
        multiRootResetRollbackTargets: [PersistedMultiRootResetRollbackTarget]? = nil,
        resetRecoveryTargets: [PersistedResetRecoveryTarget]? = nil,
        operationRecoveryAction: OperationRecoveryAction? = nil,
        autoFetchRecoveryAction: AutoFetchRecoveryAction? = nil,
        autoFetchRootPaths: [String]? = nil,
        logRevisionRanges: [PersistedLogRevisionRange]? = nil,
        operationNotificationID: String? = nil,
        findMergedReportID: String? = nil,
        rewordCommitID: String? = nil,
        rewordUndo: PersistedRewordUndo? = nil,
        uncommitCommitID: String? = nil,
        uncommitExpectedHead: String? = nil,
        uncommitExpectedBranch: String? = nil,
        rebaseUndoInitialHead: String? = nil,
        rebaseUndoExpectedHead: String? = nil,
        rebaseUndoBranch: String? = nil,
        rebaseUndoProtectionCommit: String? = nil,
        logSelectedChangesUndoInitialHead: String? = nil,
        logSelectedChangesUndoExpectedHead: String? = nil,
        logSelectedChangesUndoBranch: String? = nil
    ) {
        self.kind = kind
        self.projectPath = projectPath
        self.rootPath = rootPath
        self.shelfName = shelfName
        self.shelfPaths = shelfPaths
        self.shelfRestoreTimestamp = shelfRestoreTimestamp
        self.shelfRestoreTimestamps = shelfRestoreTimestamps
        self.savedChangesKind = savedChangesKind
        self.savedChangesID = savedChangesID
        self.shelfNames = shelfNames
        self.shelfBatchOperation = shelfBatchOperation
        self.shelfBatchTargetName = shelfBatchTargetName
        self.shelfBatchRemoveApplied = shelfBatchRemoveApplied
        self.shelfMemberGroups = shelfMemberGroups
        self.shelfMemberBatchOperation = shelfMemberBatchOperation
        self.shelfMemberBatchTargetName = shelfMemberBatchTargetName
        self.shelfDeletePlan = shelfDeletePlan
        self.shelfLifecycleOperation = shelfLifecycleOperation
        self.logApplyRecovery = logApplyRecovery
        self.externalVCSAction = externalVCSAction
        self.rebaseBranch = rebaseBranch
        self.checkoutReference = checkoutReference
        self.checkoutTargets = checkoutTargets
        self.multiRootBranchName = multiRootBranchName
        self.multiRootBranchCreateRollbackTargets = multiRootBranchCreateRollbackTargets
        self.multiRootBranchRenameOldName = multiRootBranchRenameOldName
        self.multiRootBranchRenameNewName = multiRootBranchRenameNewName
        self.multiRootBranchRenameRollbackTargets = multiRootBranchRenameRollbackTargets
        self.multiRootMergeBranchName = multiRootMergeBranchName
        self.multiRootMergeRollbackTargets = multiRootMergeRollbackTargets
        self.multiRootMergeRollbackResultRows = multiRootMergeRollbackResultRows
        self.multiRootMergeDeleteBranchName = multiRootMergeDeleteBranchName
        self.multiRootMergeDeleteRootPaths = multiRootMergeDeleteRootPaths
        self.branchDeleteRecoveryTargets = branchDeleteRecoveryTargets
        self.multiRootRetryOperation = multiRootRetryOperation
        self.multiRootRetryRootPaths = multiRootRetryRootPaths
        self.multiRootRetryPath = multiRootRetryPath
        self.multiRootRetryChangePaths = multiRootRetryChangePaths
        self.multiRootRetryUpdateRootPaths = multiRootRetryUpdateRootPaths
        self.multiRootRetryRebase = multiRootRetryRebase
        self.multiRootRetryRebaseRootPaths = multiRootRetryRebaseRootPaths
        self.multiRootRetryLogRevisionRanges = multiRootRetryLogRevisionRanges
        self.multiRootRetryResultRows = multiRootRetryResultRows
        self.multiRootRetryDetach = multiRootRetryDetach
        self.multiRootRetryCheckoutMode = multiRootRetryCheckoutMode
        self.multiRootPushTagMode = multiRootPushTagMode
        self.multiRootPushSkipHooks = multiRootPushSkipHooks
        self.multiRootPushForce = multiRootPushForce
        self.multiRootPushForceWithLease = multiRootPushForceWithLease
        self.multiRootCommitRetry = multiRootCommitRetry
        self.pushRecovery = pushRecovery
        self.stashBranchRetry = stashBranchRetry
        self.submoduleRetry = submoduleRetry
        self.submoduleUndo = submoduleUndo
        self.multiRootRebaseRecoveryAction = multiRootRebaseRecoveryAction
        self.multiRootRebaseSessionID = multiRootRebaseSessionID
        self.multiRootRebaseRollbackTargets = multiRootRebaseRollbackTargets
        self.multiRootUpdateRollbackTargets = multiRootUpdateRollbackTargets
        self.multiRootResetRollbackTargets = multiRootResetRollbackTargets
        self.resetRecoveryTargets = resetRecoveryTargets
        self.operationRecoveryAction = operationRecoveryAction
        self.autoFetchRecoveryAction = autoFetchRecoveryAction
        self.autoFetchRootPaths = autoFetchRootPaths
        self.logRevisionRanges = logRevisionRanges
        self.operationNotificationID = operationNotificationID
        self.findMergedReportID = findMergedReportID
        self.rewordCommitID = rewordCommitID
        self.rewordUndo = rewordUndo
        self.uncommitCommitID = uncommitCommitID
        self.uncommitExpectedHead = uncommitExpectedHead
        self.uncommitExpectedBranch = uncommitExpectedBranch
        self.rebaseUndoInitialHead = rebaseUndoInitialHead
        self.rebaseUndoExpectedHead = rebaseUndoExpectedHead
        self.rebaseUndoBranch = rebaseUndoBranch
        self.rebaseUndoProtectionCommit = rebaseUndoProtectionCommit
        self.logSelectedChangesUndoInitialHead = logSelectedChangesUndoInitialHead
        self.logSelectedChangesUndoExpectedHead = logSelectedChangesUndoExpectedHead
        self.logSelectedChangesUndoBranch = logSelectedChangesUndoBranch
    }
}
