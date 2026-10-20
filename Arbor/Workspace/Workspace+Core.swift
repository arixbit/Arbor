import SwiftUI
import AppKit
import UniformTypeIdentifiers

import SwiftUI
import AppKit
import UniformTypeIdentifiers
func persistedChangeKind(_ kind: ChangeKind) -> String {
    switch kind {
    case .unchanged: return "unchanged"
    case .added: return "added"
    case .modified: return "modified"
    case .deleted: return "deleted"
    case .renamed: return "renamed"
    case .copied: return "copied"
    case .typeChanged: return "typeChanged"
    case .untracked: return "untracked"
    case .ignored: return "ignored"
    case .conflicted: return "conflicted"
    }
}
func changeKind(rawValue: String) -> ChangeKind? {
    switch rawValue {
    case "unchanged": return .unchanged
    case "added": return .added
    case "modified": return .modified
    case "deleted": return .deleted
    case "renamed": return .renamed
    case "copied": return .copied
    case "typeChanged": return .typeChanged
    case "untracked": return .untracked
    case "ignored": return .ignored
    case "conflicted": return .conflicted
    default: return nil
    }
}
func isArborUpdateLocalChangesName(_ name: String) -> Bool {
    isArborTemporaryStashMessage(name) || isArborTemporaryShelfName(name)
}
/// Resolve the repository-local exclude file from Git's actual administrative
/// directory. A linked worktree's `gitDir` is `.git/worktrees/<name>`, while
/// its `commondir` points back to the shared `.git`; Git's repository-local
/// exclude file belongs to that common directory.
func repositoryGitExcludeURL(gitDirectory: URL) -> URL {
    let administrativeDirectory = gitDirectory.standardizedFileURL
    let commonDirectory = repositoryCommonGitDirectory(gitDir: administrativeDirectory)
        ?? administrativeDirectory
    return commonDirectory.appendingPathComponent("info/exclude")
}
