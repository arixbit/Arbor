import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Resolve a stash object immediately before a mutating operation. The UI
/// may have captured a stack position, but inserting or deleting another
/// stash must never redirect the operation to a different object.
func currentStashIndex(repo: Repository, stashID: String) throws -> UInt32 {
    let stashes = try repo.stashList()
    guard let index = stashes.firstIndex(where: { $0.id == stashID }) else {
        throw NSError(
            domain: "Arbor.Stash",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The selected stash no longer exists."]
        )
    }
    return UInt32(index)
}
func pullStashIndex(message: String?, in stashes: [StashInfo]) -> Int? {
    guard let message else { return nil }
    let matches = stashes.indices.filter { stashes[$0].message == message }
    guard matches.count == 1 else { return nil }
    return matches[0]
}
/// Update Project uses a stable stash message so recovery survives an app
/// restart. The Git operation state itself remains the source of truth on
/// disk; this helper only identifies Arbor's temporary local-change stash.
func isArborUpdateStashMessage(_ message: String) -> Bool {
    message == "Arbor: Update Project" || message == "Arbor: Update Project (rebase)"
}
func isArborPushRecoveryStashMessage(_ message: String) -> Bool {
    message.hasPrefix("Arbor: Push update")
}
func isArborTemporaryStashMessage(_ message: String) -> Bool {
    isArborUpdateStashMessage(message) || isArborPushRecoveryStashMessage(message)
}
struct StashClearConfirmation: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
}
func stashClearConfirmation(repositoryName: String) -> StashClearConfirmation {
    let name = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = name.isEmpty ? "the current Git root" : name
    return StashClearConfirmation(
        title: "Clear all stashes in \(displayName)?",
        message: "This permanently removes every stash in \(displayName).",
        confirmTitle: "Clear All"
    )
}
