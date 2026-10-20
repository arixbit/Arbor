import SwiftUI
import AppKit
import UniformTypeIdentifiers

func operationRecoveryNotificationID(rootPath: String) -> String {
    let stableRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.operation-recovery.\(stableRoot)"
}
func operationRecoveryNotificationRootKey(_ rootPath: String) -> String {
    URL(fileURLWithPath: rootPath).standardizedFileURL.path
}
/// Stable root-local identity for a paused Git operation. Git metadata
/// refreshes can report the same state many times; conflict resolution or a
/// rebase step can change the fingerprint and should produce a replacement
/// notice instead of being hidden by a notification-ID-only check.
func operationRecoveryNotificationFingerprint(_ state: OperationState) -> String {
    let kind: String
    switch state.kind {
    case .merge: kind = "merge"
    case .rebase: kind = "rebase"
    case .cherryPick: kind = "cherry-pick"
    case .revert: kind = "revert"
    }
    let origin: String
    switch state.origin {
    case .git: origin = "git"
    case .engine: origin = "engine"
    }
    let backend: String
    switch state.backend {
    case .merge?: backend = "merge"
    case .apply?: backend = "apply"
    case nil: backend = "none"
    }
    let conflicts = state.conflictedFiles.sorted().joined(separator: "\u{1f}")
    return [
        kind,
        origin,
        backend,
        state.interactive ? "interactive" : "non-interactive",
        state.onto ?? "",
        state.originalBranch ?? "",
        state.stepsDone.map(String.init) ?? "",
        state.stepsTotal.map(String.init) ?? "",
        state.message ?? "",
        conflicts
    ].joined(separator: "\u{1e}")
}
/// Rebuild the small engine result value needed by Push's classification
/// helpers from the persisted presentation rows. This is only used after a
/// root-scoped retry, where the current engine call contains a subset and the
/// final notification must classify the cumulative result tree.
func rootOperationResults(from rows: [FeedbackResultRow]) -> [RootOperationResult] {
    rows.map { row in
        RootOperationResult(
            rootPath: row.rootPath,
            displayName: row.displayName,
            success: row.state == .success,
            skipped: row.state == .skipped,
            message: row.detail
        )
    }
}
struct OperationAbortConfirmation: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
}
func operationAbortConfirmation(
    for kind: OperationKind,
    repositoryName: String
) -> OperationAbortConfirmation {
    let operation: String
    switch kind {
    case .merge: operation = "Merge"
    case .rebase: operation = "Rebase"
    case .cherryPick: operation = "Cherry-pick"
    case .revert: operation = "Revert"
    }
    return OperationAbortConfirmation(
        title: "Abort \(operation)?",
        message: "Abort the in-progress \(operation.lowercased()) operation in \(repositoryName)? The repository will be restored to its pre-operation state.",
        confirmTitle: "Abort"
    )
}
