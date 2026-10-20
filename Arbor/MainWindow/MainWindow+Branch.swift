import SwiftUI
import AppKit


/// IntelliJ's Compare Branches Log uses the range's exclusive side as the
/// cherry-pick target. The ordinary Log uses the repository's current branch.
func cherryPickTargetBranch(
    mode: LogViewMode,
    sourceBranch: String,
    firstBranch: String,
    secondBranch: String,
    currentBranch: String?
) -> String {
    let source = sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let first = firstBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let second = secondBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    if mode == .compareBranches {
        if source == first, !second.isEmpty { return second }
        if source == second, !first.isEmpty { return first }
    }
    let current = currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return current.isEmpty ? "HEAD" : current
}

/// The reference highlighter starts comparison only for repositories that
/// actually expose the selected source branch. Missing branches in other
/// roots are skipped rather than reported as failed comparisons.
func cherryPickSourceBranchExists(
    _ sourceBranch: String,
    localBranchNames: [String],
    remoteBranchNames: [String]
) -> Bool {
    let source = sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else { return false }
    return localBranchNames.contains(source) || remoteBranchNames.contains(source)
}

enum LogBranchSelectionAction: String, CaseIterable, Identifiable {
    case navigate
    case filter
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigate: "Navigate Log"
        case .filter: "Filter Log"
        case .none: "Select Only"
        }
    }
}

/// A branch filter keeps the owning Git root attached to the ref. IntelliJ's
/// multi-root VCS Log treats two equal branch names in different roots as
/// different navigations and filters; a bare branch name cannot represent
/// that distinction.
struct LogRootBranchFilter: Codable, Equatable, Hashable, Sendable {
    let rootPath: String
    let branch: String
}

struct BranchDeleteRecoveryContext: Identifiable {
    let repo: Repository
    let preview: BranchDeletePreview
    let rootPath: String?
    let trackedRemoteBranch: String?

    init(
        repo: Repository,
        preview: BranchDeletePreview,
        rootPath: String?,
        trackedRemoteBranch: String? = nil
    ) {
        self.repo = repo
        self.preview = preview
        self.rootPath = rootPath
        self.trackedRemoteBranch = trackedRemoteBranch
    }

    var id: String {
        "\(rootPath ?? "current"):\(preview.branchName):\(preview.tipId)"
    }
}

struct MultiRootBranchDeleteRecoveryContext: Identifiable {
    let branchName: String
    let contexts: [BranchDeleteRecoveryContext]

    var id: String {
        "multi-root:\(branchName):\(contexts.map(\.id).joined(separator: "|"))"
    }
}

struct BranchCleanupSelection: Hashable {
    let rootPath: String
    let branchName: String
}

struct BranchCleanupRoot: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let branches: [BranchInfo]
    let trackingByBranch: [String: String]
    let mergedBranches: Set<String>
    let calculatedTarget: String?
    let calculatedPrefix: String?
    let calculationError: String?

    init(
        rootPath: String,
        displayName: String,
        relativePath: String,
        branches: [BranchInfo],
        trackingByBranch: [String: String],
        mergedBranches: Set<String>,
        calculatedTarget: String?,
        calculatedPrefix: String?,
        calculationError: String? = nil
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.relativePath = relativePath
        self.branches = branches
        self.trackingByBranch = trackingByBranch
        self.mergedBranches = mergedBranches
        self.calculatedTarget = calculatedTarget
        self.calculatedPrefix = calculatedPrefix
        self.calculationError = calculationError
    }

    var id: String { rootPath }
}
