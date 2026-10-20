import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Changes Browser rows keep the owning Git root in their identity. A commit
/// object ID is only repository-local, so using the bare ID here would merge
/// two independent repositories when an aggregate Log selection contains the
/// same object ID in both roots.
func logChangesCommitIdentity(_ commit: CommitInfo) -> String {
    logCommitDisplayIdentity(
        repositoryPath: commit.repositoryPath,
        id: commit.id,
        aggregate: true
    )
}
