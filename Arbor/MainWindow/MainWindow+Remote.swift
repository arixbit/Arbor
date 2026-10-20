import SwiftUI
import AppKit


struct AddCommitsToRemoteBranchContext: Identifiable {
    let commits: [CommitInfo]
    let remoteBranches: [RemoteBranchInfo]

    var id: String {
        "add-commits-to-remote:\(commits.map(\.id).joined(separator: ","))"
    }
}

struct MultiRootRemoteConfigContext: Identifiable {
    let rootPath: String
    let remotes: [RemoteInfo]

    var id: String { rootPath }
}

struct MultiRootUpstreamContext: Identifiable {
    let rootPath: String
    let displayName: String
    let localBranch: String
    let remoteBranches: [RemoteBranchInfo]
    let currentUpstream: String?

    var id: String { "\(rootPath):\(localBranch)" }
}

struct MultiRootRemoteConfigRoot: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let remotes: [RemoteInfo]

    var id: String { rootPath }
}

struct MultiRootRemoteConfigAggregateContext: Identifiable {
    let roots: [MultiRootRemoteConfigRoot]

    var id: String { "multi-root-remotes" }
}
