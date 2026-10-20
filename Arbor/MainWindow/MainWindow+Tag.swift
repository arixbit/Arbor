import SwiftUI
import AppKit


struct TagDeleteRecoveryContext: Identifiable {
    let repo: Repository
    let tag: TagInfo
    let rootPath: String?

    var remotes: [RemoteInfo] {
        (try? repo.remoteList()) ?? []
    }

    var id: String { "\(rootPath ?? "current"):\(tag.name):\(tag.id)" }
}

struct MultiRootTagDeleteRecoveryContext: Identifiable {
    let tagName: String
    let contexts: [TagDeleteRecoveryContext]

    var id: String {
        "multi-root-tags:\(tagName):\(contexts.map(\.id).joined(separator: "|"))"
    }
}
