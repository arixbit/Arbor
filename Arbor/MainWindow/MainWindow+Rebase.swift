import SwiftUI
import AppKit


enum AutoSquashCommitKind: Equatable, Sendable {
    case fixup
    case squash

    var prefix: String {
        switch self {
        case .fixup: "fixup"
        case .squash: "squash"
        }
    }

    var title: String {
        switch self {
        case .fixup: "Fixup"
        case .squash: "Squash"
        }
    }
}

struct PendingAutoSquashRebase: Equatable, Sendable {
    let targetID: String
    let onto: String
    let kind: AutoSquashCommitKind
    let root: Bool
}

struct RebaseRetryContext {
    let repositoryPath: String
    let branch: String
    let onto: String
    let actions: [RebaseAction]
    let interactive: Bool
    let preserveMerges: Bool
    let autoSquash: Bool
    let keepEmpty: Bool
    let updateRefs: Bool
    let root: Bool
}

struct RebaseUndoSeed: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let initialHead: String
    let updateRefs: Bool
    /// The oldest commit in the exact pre-rebase range, when the operation
    /// supplied or resolved an upstream/onto revision. Older persisted seeds
    /// may leave this nil and use the conservative old/new HEAD fallback.
    let protectionCommitID: String?

    init(
        repositoryPath: String,
        branch: String,
        initialHead: String,
        updateRefs: Bool,
        protectionCommitID: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.initialHead = initialHead
        self.updateRefs = updateRefs
        self.protectionCommitID = protectionCommitID
    }
}

struct RebaseUndoTarget: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let initialHead: String
    let expectedHead: String
    let protectionCommitID: String?

    init(
        repositoryPath: String,
        branch: String,
        initialHead: String,
        expectedHead: String,
        protectionCommitID: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.protectionCommitID = protectionCommitID
    }
}

/// Persisted form of a rebase action. UniFFI enums are intentionally kept out
/// of the on-disk model so an interrupted multi-root session can be restored
/// without depending on generated Swift enum Codable conformance.
enum PersistedRebaseActionKind: String, Codable, Equatable, Sendable {
    case pick
    case drop
    case reword
    case squash
    case fixup
    case edit
}

struct PersistedRebaseAction: Codable, Equatable, Sendable {
    let kind: PersistedRebaseActionKind
    let message: String?

    init(action: RebaseAction) {
        switch action {
        case .pick:
            kind = .pick
            message = nil
        case .drop:
            kind = .drop
            message = nil
        case let .reword(message: message):
            kind = .reword
            self.message = message
        case .squash:
            kind = .squash
            message = nil
        case let .squashWithMessage(message: message):
            kind = .squash
            self.message = message
        case .fixup:
            kind = .fixup
            message = nil
        case .edit:
            kind = .edit
            message = nil
        }
    }

    func makeAction() -> RebaseAction {
        switch kind {
        case .pick: return .pick
        case .drop: return .drop
        case .reword: return .reword(message: message ?? "")
        case .squash:
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .squashWithMessage(message: message)
            }
            return .squash
        case .fixup: return .fixup
        case .edit: return .edit
        }
    }
}

enum MultiRootRebaseSessionState: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case paused
    case failed
    case aborted
}

struct MultiRootRebaseSessionRoot: Codable, Equatable, Identifiable, Sendable {
    let rootPath: String
    let displayName: String
    let branch: String
    let onto: String
    let actions: [PersistedRebaseAction]
    /// Visible structured todo order for preserve-merges. Optional keeps
    /// previously persisted partial sessions decodable.
    let orderedCommitIds: [String]?
    /// Optional raw native todo for this repository. Native todo text is
    /// repository-specific and must survive a partial multi-root retry.
    let rawTodo: String?
    let preserveMerges: Bool
    let autoSquash: Bool
    let keepEmpty: Bool
    let updateRefs: Bool
    let root: Bool
    /// Persist the policy with the batch so a relaunch cannot silently switch
    /// an in-flight rebase from Shelf to Stash (or vice versa).
    let savePolicyRaw: String?
    /// Captured before the root starts rewriting history. Older persisted
    /// sessions may leave this nil and use the conservative fallback.
    var protectionCommitID: String? = nil
    var state: MultiRootRebaseSessionState
    var initialHead: String?
    var expectedHead: String?
    var initialBranch: String?
    var message: String

    var id: String { rootPath }

    func makeSpec() -> MultiRootRebaseSpec {
        MultiRootRebaseSpec(
            rootPath: rootPath,
            branch: branch,
            onto: onto,
            actions: actions.map { $0.makeAction() },
            orderedCommitIds: orderedCommitIds ?? [],
            rawTodo: rawTodo,
            preserveMerges: preserveMerges,
            autoSquash: autoSquash,
            keepEmpty: keepEmpty,
            updateRefs: updateRefs,
            root: root,
            interactive: !actions.isEmpty,
            savePolicy: savePolicyRaw == GitLocalChangesSavePolicyChoice.shelve.rawValue
                ? .shelve
                : .stash
        )
    }
}

struct MultiRootRebaseSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectPath: String
    var roots: [MultiRootRebaseSessionRoot]

    init(projectPath: String, roots: [MultiRootRebaseSessionRoot]) {
        self.id = UUID()
        self.projectPath = projectPath
        self.roots = roots
    }
}

struct MultiRootRebaseRollbackTarget: Identifiable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let branch: String
    let protectionCommitID: String?

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        branch: String,
        protectionCommitID: String? = nil
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.branch = branch
        self.protectionCommitID = protectionCommitID
    }

    var id: String { "\(rootPath):\(initialHead):\(expectedHead)" }
}

struct MultiRootRebaseRollbackContext: Identifiable {
    let sessionID: UUID
    let branch: String
    let targets: [MultiRootRebaseRollbackTarget]
    let failures: [String]

    var id: String {
        "multi-root-rebase:\(sessionID.uuidString):\(targets.map(\.id).joined(separator: "|"))"
    }
}
