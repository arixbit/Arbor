import SwiftUI
import AppKit


/// VCS Log uses the repository root together with the object id as the row
/// identity when several Git roots are shown in one graph. Keep the same
/// identity for async decorations such as cherry-picked highlighting.
func logCommitDisplayIdentity(repositoryPath: String?, id: String, aggregate: Bool) -> String {
    guard aggregate,
          let repositoryPath,
          !repositoryPath.isEmpty else {
        return id
    }
    return "\(repositoryPath)\u{1f}\(id)"
}
