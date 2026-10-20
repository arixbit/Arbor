import Foundation

/// Codable form of the exact roots that completed a multi-root checkout.
/// The live UniFFI record intentionally stays process-local; this form lets
/// the rollback action survive an app restart without re-discovering a
/// different set of roots.
struct PersistedMultiRootCheckoutTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let checkedOut: Bool
    let previousBranch: String?
    let previousHead: String?
    let expectedHead: String?
    let expectedBranch: String?
    let createdBranch: String?

    init(_ target: MultiRootBranchTarget) {
        rootPath = target.rootPath
        checkedOut = target.checkedOut
        previousBranch = target.previousBranch
        previousHead = target.previousHead
        expectedHead = target.expectedHead
        expectedBranch = target.expectedBranch
        createdBranch = target.createdBranch
    }

    func makeLiveTarget() -> MultiRootBranchTarget {
        MultiRootBranchTarget(
            rootPath: rootPath,
            checkedOut: checkedOut,
            previousBranch: previousBranch,
            previousHead: previousHead,
            expectedHead: expectedHead,
            expectedBranch: expectedBranch,
            createdBranch: createdBranch
        )
    }
}

/// Codable state for a multi-root New Branch partial rollback. Unlike a
/// checkout target, an existing branch may need its previous tip restored
/// rather than deleted.
struct PersistedMultiRootBranchCreateTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let checkedOut: Bool
    let previousBranch: String?
    let previousHead: String?
    let expectedHead: String?
    let expectedBranch: String?
    let previousBranchTip: String?
    let expectedBranchTip: String?

    init(_ target: MultiRootBranchCreateTarget) {
        rootPath = target.rootPath
        checkedOut = target.checkedOut
        previousBranch = target.previousBranch
        previousHead = target.previousHead
        expectedHead = target.expectedHead
        expectedBranch = target.expectedBranch
        previousBranchTip = target.previousBranchTip
        expectedBranchTip = target.expectedBranchTip
    }

    func makeLiveTarget() -> MultiRootBranchCreateTarget {
        MultiRootBranchCreateTarget(
            rootPath: rootPath,
            checkedOut: checkedOut,
            previousBranch: previousBranch,
            previousHead: previousHead,
            expectedHead: expectedHead,
            expectedBranch: expectedBranch,
            previousBranchTip: previousBranchTip,
            expectedBranchTip: expectedBranchTip
        )
    }
}

/// Codable post-rename state for a multi-root branch rollback. The rollback
/// only renames the new ref back when the ref tip and current branch identity
/// still match this snapshot; a later user change therefore fails closed.
struct PersistedMultiRootBranchRenameRollbackTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let oldName: String
    let newName: String
    let expectedNewTip: String
    /// Empty string represents detached HEAD.
    let expectedCurrentBranch: String
    /// Upstream after the forward rename; nil means no tracking ref.
    let expectedUpstream: String?
    let upstream: String?
}

/// The exact ref and warning snapshot captured before a local branch deletion.
/// Keeping this data instead of a Repository handle makes both Restore and
/// View Commits safe to carry through Operation Log/native notifications.
struct PersistedBranchDeleteCommit: Codable, Equatable, Sendable {
    let id: String
    let shortID: String
    let summary: String
    let time: Int64
}

struct PersistedBranchDeleteRecoveryTarget: Codable, Equatable, Sendable {
    let rootPath: String
    let branchName: String
    let tipID: String
    let upstream: String?
    let baseBranches: [String]
    let unmergedCommits: [PersistedBranchDeleteCommit]

    init(
        rootPath: String,
        branchName: String,
        tipID: String,
        upstream: String?,
        baseBranches: [String] = [],
        unmergedCommits: [PersistedBranchDeleteCommit] = []
    ) {
        self.rootPath = rootPath
        self.branchName = branchName
        self.tipID = tipID
        self.upstream = upstream
        self.baseBranches = baseBranches
        self.unmergedCommits = unmergedCommits
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath
        case branchName
        case tipID
        case upstream
        case baseBranches
        case unmergedCommits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        branchName = try container.decode(String.self, forKey: .branchName)
        tipID = try container.decode(String.self, forKey: .tipID)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        baseBranches = try container.decodeIfPresent([String].self, forKey: .baseBranches) ?? []
        unmergedCommits = try container.decodeIfPresent(
            [PersistedBranchDeleteCommit].self,
            forKey: .unmergedCommits
        ) ?? []
    }
}
