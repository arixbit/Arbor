import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CheckoutReferenceTarget: Sendable {
    case localBranch(String)
    case remoteBranch(String)
    case detached(String)
}
func resolveCheckoutReferenceTarget(
    repo: Repository,
    reference: String
) -> CheckoutReferenceTarget {
    let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let localCandidates = [
        normalized,
        normalized.hasPrefix("refs/heads/")
            ? String(normalized.dropFirst("refs/heads/".count))
            : normalized
    ]
    if let branch = (try? repo.branchList())?.first(where: { localCandidates.contains($0.name) }) {
        return .localBranch(branch.name)
    }

    let remoteCandidates = [
        normalized,
        normalized.hasPrefix("refs/remotes/")
            ? String(normalized.dropFirst("refs/remotes/".count))
            : normalized
    ]
    if let branch = (try? repo.remoteBranchList())?.first(where: { remoteCandidates.contains($0.name) }) {
        return .remoteBranch(branch.name)
    }

    return .detached(normalized)
}
func performCheckoutReference(
    repo: Repository,
    target: CheckoutReferenceTarget
) throws {
    switch target {
    case let .localBranch(name):
        try repo.switchBranch(name: name)
    case let .remoteBranch(name):
        try repo.checkoutRemoteBranch(remoteBranch: name, localName: nil)
    case let .detached(reference):
        try repo.checkoutDetached(commitId: reference)
    }
}
