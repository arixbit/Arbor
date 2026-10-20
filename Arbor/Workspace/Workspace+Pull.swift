import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PullLocalChangesPreservation: Codable, Equatable, Sendable {
    let shelfName: String?
    let stashMessage: String?
    /// Stable identity for the temporary Pull stash. Older persisted markers
    /// may omit this and continue to use the unique message fallback.
    let stashID: String?

    init(shelfName: String?, stashMessage: String?, stashID: String? = nil) {
        self.shelfName = shelfName
        self.stashMessage = stashMessage
        self.stashID = stashID
    }
}
func pendingPullPreservationKey(repositoryPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.pull-preservation.v1.\(encoded)"
}
func pendingPullPreservationNotificationID(repositoryPath: String) -> String {
    pendingPullPreservationKey(repositoryPath: repositoryPath)
}
func savePendingPullPreservation(
    repositoryPath: String,
    preservation: PullLocalChangesPreservation
) {
    guard preservation.shelfName != nil
        || preservation.stashMessage != nil
        || preservation.stashID != nil,
          let data = try? JSONEncoder().encode(preservation) else { return }
    UserDefaults.standard.set(
        data,
        forKey: pendingPullPreservationKey(repositoryPath: repositoryPath)
    )
}
func loadPendingPullPreservation(
    repositoryPath: String
) -> PullLocalChangesPreservation? {
    guard let data = UserDefaults.standard.data(
        forKey: pendingPullPreservationKey(repositoryPath: repositoryPath)
    ) else {
        return nil
    }
    return try? JSONDecoder().decode(PullLocalChangesPreservation.self, from: data)
}
func clearPendingPullPreservation(repositoryPath: String) {
    UserDefaults.standard.removeObject(
        forKey: pendingPullPreservationKey(repositoryPath: repositoryPath)
    )
}
