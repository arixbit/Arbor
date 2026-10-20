import Foundation

/// Codable identity for a Changes Browser row. The owning root is part of the
/// identity because the same relative path can exist in multiple nested Git
/// repositories. Batch stage/unstage retry actions persist this pair rather
/// than relying on the currently discovered project roots.
struct PersistedMultiRootChangePath: Codable, Equatable, Sendable {
    let rootPath: String
    let path: String
    let oldPath: String?

    init(_ selection: MultiRootChangeSelection) {
        rootPath = selection.rootPath
        path = selection.path
        oldPath = selection.oldPath
    }

    init(rootPath: String, path: String, oldPath: String? = nil) {
        self.rootPath = rootPath
        self.path = path
        self.oldPath = oldPath
    }

    func makeLiveSelection() -> MultiRootChangeSelection {
        MultiRootChangeSelection(rootPath: rootPath, path: path, oldPath: oldPath)
    }
}

/// The immutable range attached to IntelliJ's update-session "View Commits"
/// action. A range must retain its owning Git root because the same object id
/// is not a project-wide identity in a multi-root workspace.
struct PersistedLogRevisionRange: Codable, Equatable, Sendable {
    let rootPath: String
    let oldRevision: String
    let newRevision: String
}

/// Codable commit context for a multi-root retry action. The generated
/// UniFFI options type intentionally stays a live-process value; notifications
/// and Operation Log entries need a stable on-disk representation instead.
struct PersistedMultiRootCommitCheck: Codable, Equatable, Sendable {
    let command: String
    let args: [String]

    init(_ check: MultiRootCommitCheck) {
        command = check.command
        args = check.args
    }

    func makeLive() -> MultiRootCommitCheck {
        MultiRootCommitCheck(command: command, args: args)
    }
}

struct PersistedMultiRootCommitRetry: Codable, Equatable, Sendable {
    let message: String
    let skipHooks: Bool
    let authorName: String?
    let authorEmail: String?
    let committerName: String?
    let committerEmail: String?
    let signOff: Bool
    let coAuthors: [String]
    let amend: Bool
    let runBeforeCommitChecks: Bool
    let beforeCommitCommands: [PersistedMultiRootCommitCheck]
    /// Optional for backwards-compatible history entries created before the
    /// project-level Commit and Push executor existed.
    let pushAfterCommit: Bool?
    let pushRootPaths: [String]?
    /// When present, retry only these root-qualified Changes Browser rows.
    /// Nil preserves the older root-level Commit retry payload.
    let selectedPaths: [PersistedMultiRootChangePath]?

    init(
        message: String,
        options: MultiRootCommitOptions,
        pushAfterCommit: Bool = false,
        pushRootPaths: [String] = [],
        selectedPaths: [PersistedMultiRootChangePath]? = nil
    ) {
        self.message = message
        skipHooks = options.skipHooks
        authorName = options.authorName
        authorEmail = options.authorEmail
        committerName = options.committerName
        committerEmail = options.committerEmail
        signOff = options.signOff
        coAuthors = options.coAuthors
        amend = options.amend
        runBeforeCommitChecks = options.runBeforeCommitChecks
        beforeCommitCommands = options.beforeCommitCommands.map(PersistedMultiRootCommitCheck.init)
        self.pushAfterCommit = pushAfterCommit ? true : nil
        self.pushRootPaths = pushRootPaths.isEmpty ? nil : pushRootPaths
        self.selectedPaths = selectedPaths
    }

    func makeLiveOptions() -> MultiRootCommitOptions {
        MultiRootCommitOptions(
            skipHooks: skipHooks,
            authorName: authorName,
            authorEmail: authorEmail,
            committerName: committerName,
            committerEmail: committerEmail,
            signOff: signOff,
            coAuthors: coAuthors,
            amend: amend,
            runBeforeCommitChecks: runBeforeCommitChecks,
            beforeCommitCommands: beforeCommitCommands.map { $0.makeLive() }
        )
    }
}

/// Durable parameters for a rejected single-root Push. The recovery action is
/// intentionally limited to the checked-out branch: custom refspecs and
/// detached sources cannot be repaired by pulling the current branch without
/// risking a push of the wrong object.
struct PersistedPushRecovery: Codable, Equatable, Sendable {
    let remote: String
    let branch: String
    let force: Bool
    let forceWithLease: Bool
    let setUpstream: Bool
    /// Preserve a custom source/target refspec for a direct Push retry. A
    /// rejected refspec push cannot safely be reconstructed from the current
    /// branch alone.
    let refspec: String?
    let tagModeRaw: String?
    let skipHooks: Bool
    let rebase: Bool

    init(
        remote: String,
        branch: String,
        force: Bool,
        forceWithLease: Bool,
        setUpstream: Bool,
        refspec: String? = nil,
        tagModeRaw: String? = nil,
        skipHooks: Bool = false,
        rebase: Bool
    ) {
        self.remote = remote
        self.branch = branch
        self.force = force
        self.forceWithLease = forceWithLease
        self.setUpstream = setUpstream
        self.refspec = refspec
        self.tagModeRaw = tagModeRaw
        self.skipHooks = skipHooks
        self.rebase = rebase
    }
}

/// Expected-state context for undoing a successful commit reword. Reword only
/// changes commit objects, so the narrow ref-only rollback preserves the index
/// and worktree while still refusing stale notifications or a different branch.
struct PersistedRewordUndo: Codable, Equatable, Sendable {
    let initialHeadID: String
    let expectedHeadID: String
    /// Empty means detached HEAD; a non-empty value is the exact local branch.
    let expectedBranch: String
}

/// Durable context for a Log Revert/Cherry-pick that has not reached a
/// terminal result. The initial HEAD is a compare-and-swap guard: a retry is
/// only offered while the repository still points at the commit that the
/// original action observed.
struct PersistedLogApplyRecovery: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case cherryPick
        case revert
    }

    let operation: Operation
    let rootPath: String
    let commitIDs: [String]
    let sessionID: String
    let batchIndex: Int
    let batchCount: Int
    let initialHead: String
    let preserveLocalChanges: Bool
    let emptyPolicyRaw: String
    let appendPublishedSuffix: Bool
    let savePolicyRaw: String
    /// Paths reported by Git when local changes block the apply. Keeping them
    /// in the recovery marker lets a reloaded notification still offer the
    /// same Show Files action as the original operation.
    let affectedPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case operation
        case rootPath
        case commitIDs
        case sessionID
        case batchIndex
        case batchCount
        case initialHead
        case preserveLocalChanges
        case emptyPolicyRaw
        case appendPublishedSuffix
        case savePolicyRaw
        case affectedPaths
    }

    init(
        operation: Operation,
        rootPath: String,
        commitIDs: [String],
        sessionID: String,
        batchIndex: Int,
        batchCount: Int,
        initialHead: String,
        preserveLocalChanges: Bool,
        emptyPolicyRaw: String,
        appendPublishedSuffix: Bool,
        savePolicyRaw: String,
        affectedPaths: [String] = []
    ) {
        self.operation = operation
        self.rootPath = rootPath
        self.commitIDs = commitIDs
        self.sessionID = sessionID
        self.batchIndex = batchIndex
        self.batchCount = batchCount
        self.initialHead = initialHead
        self.preserveLocalChanges = preserveLocalChanges
        self.emptyPolicyRaw = emptyPolicyRaw
        self.appendPublishedSuffix = appendPublishedSuffix
        self.savePolicyRaw = savePolicyRaw
        self.affectedPaths = affectedPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(Operation.self, forKey: .operation)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        commitIDs = try container.decode([String].self, forKey: .commitIDs)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? "legacy:\(rootPath)"
        batchIndex = try container.decodeIfPresent(Int.self, forKey: .batchIndex) ?? 0
        batchCount = max(
            try container.decodeIfPresent(Int.self, forKey: .batchCount) ?? 1,
            1
        )
        initialHead = try container.decode(String.self, forKey: .initialHead)
        preserveLocalChanges = try container.decode(Bool.self, forKey: .preserveLocalChanges)
        emptyPolicyRaw = try container.decode(String.self, forKey: .emptyPolicyRaw)
        appendPublishedSuffix = try container.decode(Bool.self, forKey: .appendPublishedSuffix)
        savePolicyRaw = try container.decode(String.self, forKey: .savePolicyRaw)
        affectedPaths = try container.decodeIfPresent([String].self, forKey: .affectedPaths) ?? []
    }

    func updating(
        preserveLocalChanges: Bool? = nil,
        affectedPaths: [String]? = nil
    ) -> PersistedLogApplyRecovery {
        PersistedLogApplyRecovery(
            operation: operation,
            rootPath: rootPath,
            commitIDs: commitIDs,
            sessionID: sessionID,
            batchIndex: batchIndex,
            batchCount: batchCount,
            initialHead: initialHead,
            preserveLocalChanges: preserveLocalChanges ?? self.preserveLocalChanges,
            emptyPolicyRaw: emptyPolicyRaw,
            appendPublishedSuffix: appendPublishedSuffix,
            savePolicyRaw: savePolicyRaw,
            affectedPaths: affectedPaths ?? self.affectedPaths
        )
    }
}
