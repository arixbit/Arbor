import Foundation

/// Codable form of the expected-HEAD guarded targets used by multi-root
/// rebase rollback/undo. The live SwiftUI context is process-local; these
/// immutable values make the recovery action safe to carry across relaunch.
struct PersistedMultiRootRebaseRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let branch: String
    let protectionCommitID: String?

    init(_ target: MultiRootRebaseRollbackTarget) {
        rootPath = target.rootPath
        displayName = target.displayName
        initialHead = target.initialHead
        expectedHead = target.expectedHead
        branch = target.branch
        protectionCommitID = target.protectionCommitID
    }

    func makeLiveTarget() -> MultiRootRebaseRollbackTarget {
        MultiRootRebaseRollbackTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            branch: branch,
            protectionCommitID: protectionCommitID
        )
    }
}

/// Codable expected-HEAD targets for a multi-root Merge rollback. The target
/// carries enough state to fail closed after relaunch or a later user change.
struct PersistedMultiRootMergeRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let operationPending: Bool

    init(_ target: MultiRootMergeRollbackTarget) {
        rootPath = target.rootPath
        displayName = target.displayName
        initialHead = target.initialHead
        expectedHead = target.expectedHead
        operationPending = target.operationPending
    }

    func makeLiveTarget() -> MultiRootMergeRollbackTarget {
        MultiRootMergeRollbackTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            operationPending: operationPending
        )
    }
}

/// Codable expected-HEAD targets for a compound Update Project rollback. The
/// expected branch is empty for detached HEAD and protects against a user
/// switching to another ref that happens to point at the same commit.
struct PersistedMultiRootUpdateRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let expectedHeadBranch: String?
    let ignoredPaths: [String]

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        expectedHeadBranch: String? = nil,
        ignoredPaths: [String] = []
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.expectedHeadBranch = expectedHeadBranch
        self.ignoredPaths = ignoredPaths
    }
}

/// Codable expected-HEAD targets for a soft-reset rollback. Soft reset only
/// moves the ref, so the corresponding engine action intentionally does not
/// carry or restore index/worktree snapshots.
struct PersistedMultiRootResetRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    /// Empty string represents detached HEAD.
    let expectedHeadBranch: String?

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        expectedHeadBranch: String?
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.expectedHeadBranch = expectedHeadBranch
    }

    func makeLiveTarget() -> MultiRootResetRollbackTarget {
        MultiRootResetRollbackTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            mode: .soft,
            expectedHeadBranch: expectedHeadBranch
        )
    }
}

/// Durable full-scene Reset undo context. The mode is stored as a small
/// Codable value so Operation Log/native notifications remain independent of
/// the generated UniFFI enum representation.
enum PersistedResetMode: String, Codable, Sendable {
    case soft
    case mixed
    case hard
    case keep

    init(_ mode: ResetMode) {
        switch mode {
        case .soft: self = .soft
        case .mixed: self = .mixed
        case .hard: self = .hard
        case .keep: self = .keep
        }
    }

    var live: ResetMode {
        switch self {
        case .soft: return .soft
        case .mixed: return .mixed
        case .hard: return .hard
        case .keep: return .keep
        }
    }
}

struct PersistedResetRecoveryTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let expectedHeadBranch: String?
    let mode: PersistedResetMode
    let rollbackID: String

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        expectedHeadBranch: String?,
        mode: ResetMode,
        rollbackID: String
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.expectedHeadBranch = expectedHeadBranch
        self.mode = PersistedResetMode(mode)
        self.rollbackID = rollbackID
    }

    func makeLiveTarget() -> ResetRecoveryTarget {
        ResetRecoveryTarget(
            rootPath: rootPath,
            displayName: displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            expectedHeadBranch: expectedHeadBranch,
            mode: mode.live,
            rollbackId: rollbackID
        )
    }
}
