import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BranchDashboardComparisonPair: Equatable, Sendable {
    let rootPath: String
    let first: String
    let second: String
}
/// Resolves the pair that IntelliJ's BranchesPairActionBase hands to
/// GitBrancher. A synthetic HEAD is never passed through as the literal ref
/// name: it represents the current named branch, when one exists.
func branchDashboardComparisonPair(
    selection: [BranchDashboardReference]
) -> BranchDashboardComparisonPair? {
    guard selection.count == 2,
          let first = selection.first,
          selection.allSatisfy({ $0.rootPath == first.rootPath }),
          selection.allSatisfy({ $0.kind != .tag }) else {
        return nil
    }

    if let head = selection.first(where: { $0.kind == .head }) {
        guard selection.filter({ $0.kind == .head }).count == 1,
              head.hasHeadCommit,
              let currentBranch = head.headBranchName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentBranch.isEmpty,
              let other = selection.first(where: { $0.kind != .head }),
              other.name != currentBranch else {
            return nil
        }
        return BranchDashboardComparisonPair(
            rootPath: first.rootPath,
            first: other.name,
            second: currentBranch
        )
    }

    guard selection[0].name != selection[1].name else { return nil }
    return BranchDashboardComparisonPair(
        rootPath: first.rootPath,
        first: selection[0].name,
        second: selection[1].name
    )
}
