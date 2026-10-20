import Foundation

enum PersistedSubmoduleOperation: String, Codable, Equatable, Sendable {
    case add
    case update
    case sync
    case deinitialize = "deinit"
    case remove
    case setBranch
}

/// Durable context for a standalone SubmodulePanel operation. The request is
/// intentionally independent of the live SwiftUI fields so a failed command
/// can be retried from Operation Log after the window or application reloads.
struct PersistedSubmoduleRetry: Codable, Equatable, Sendable {
    let operation: PersistedSubmoduleOperation
    let url: String?
    let path: String?
    let branch: String?
    let force: Bool?
    let initFlag: Bool?
    let recursive: Bool?
    let remote: Bool?

    init(
        operation: PersistedSubmoduleOperation,
        url: String? = nil,
        path: String? = nil,
        branch: String? = nil,
        force: Bool? = nil,
        initFlag: Bool? = nil,
        recursive: Bool? = nil,
        remote: Bool? = nil
    ) {
        self.operation = operation
        self.url = url
        self.path = path
        self.branch = branch
        self.force = force
        self.initFlag = initFlag
        self.recursive = recursive
        self.remote = remote
    }
}

enum PersistedSubmoduleUndoOperation: String, Codable, Equatable, Sendable {
    case add
    case deinitialize = "deinit"
    case remove
}

/// Expected-state context for a reversible submodule operation. Undo is only
/// offered when the operation can restore the exact gitlink without guessing
/// about .gitmodules or overwriting files created after the original action.
struct PersistedSubmoduleUndo: Codable, Equatable, Sendable {
    let operation: PersistedSubmoduleUndoOperation
    let path: String
    let expectedHeadID: String
    let expectedGitmodulesPresent: Bool
    let expectedGitmodulesContents: String?
    let expectedParentHeadID: String?
    let restoreGitmodulesPresent: Bool?
    let restoreGitmodulesContents: String?

    init(
        operation: PersistedSubmoduleUndoOperation,
        path: String,
        expectedHeadID: String,
        expectedGitmodulesPresent: Bool,
        expectedGitmodulesContents: String?,
        expectedParentHeadID: String? = nil,
        restoreGitmodulesPresent: Bool? = nil,
        restoreGitmodulesContents: String? = nil
    ) {
        self.operation = operation
        self.path = path
        self.expectedHeadID = expectedHeadID
        self.expectedGitmodulesPresent = expectedGitmodulesPresent
        self.expectedGitmodulesContents = expectedGitmodulesContents
        self.expectedParentHeadID = expectedParentHeadID
        self.restoreGitmodulesPresent = restoreGitmodulesPresent
        self.restoreGitmodulesContents = restoreGitmodulesContents
    }
}
