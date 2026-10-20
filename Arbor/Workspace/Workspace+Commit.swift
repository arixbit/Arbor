import SwiftUI
import AppKit
import UniformTypeIdentifiers

func commitWarningSetting(for kind: CommitCheckKind) -> GitCommitWarningSetting? {
    switch kind {
    case .crlfWarning: return .crlf
    case .detachedHead, .rebaseInProgress: return .detachedHead
    case .largeFile: return .largeFile
    case .badFileName: return .badFileName
    default: return nil
    }
}
func oldestSelectedLinearCommit(
    _ commits: [CommitInfo],
    isAncestor: (String, String) -> Bool
) -> CommitInfo? {
    let candidates = commits.filter { candidate in
        commits.allSatisfy { other in
            candidate.id == other.id || isAncestor(candidate.id, other.id)
        }
    }
    guard candidates.count == 1 else { return nil }
    return candidates[0]
}
/// A small persisted snapshot used only to make the first Log paint faster
/// after relaunch. Git remains authoritative: the snapshot is accepted only
/// when the root, query, and all visible ref tips still match the token read
/// from the repository immediately before the fresh Rust query.
struct PersistedLogCacheCommit: Codable, Equatable, Sendable {
    let id: String
    let repositoryPath: String?
    let shortID: String
    let summary: String
    let authorName: String
    let authorEmail: String
    let committerName: String
    let committerEmail: String
    let messageBody: String
    let hasSignature: Bool
    let time: Int64
    let parentIDs: [String]
    let refs: [String]
    let tagRefs: [String]
    let remoteRefs: [String]
    let isHead: Bool
    let lane: UInt32
    let parentLanes: [UInt32]

    init(_ commit: CommitInfo) {
        id = commit.id
        repositoryPath = commit.repositoryPath
        shortID = commit.shortId
        summary = commit.summary
        authorName = commit.authorName
        authorEmail = commit.authorEmail
        committerName = commit.committerName
        committerEmail = commit.committerEmail
        messageBody = commit.messageBody
        hasSignature = commit.hasSignature
        time = commit.time
        parentIDs = commit.parentIds
        refs = commit.refs
        tagRefs = commit.tagRefs
        remoteRefs = commit.remoteRefs
        isHead = commit.isHead
        lane = commit.lane
        parentLanes = commit.parentLanes
    }

    var commitInfo: CommitInfo {
        CommitInfo(
            id: id,
            repositoryPath: repositoryPath,
            shortId: shortID,
            summary: summary,
            authorName: authorName,
            authorEmail: authorEmail,
            committerName: committerName,
            committerEmail: committerEmail,
            messageBody: messageBody,
            hasSignature: hasSignature,
            time: time,
            parentIds: parentIDs,
            refs: refs,
            tagRefs: tagRefs,
            remoteRefs: remoteRefs,
            isHead: isHead,
            lane: lane,
            parentLanes: parentLanes
        )
    }
}
func uncommitChangedPaths(_ changes: [TreeChange]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for change in changes {
        for path in [change.oldPath, change.path].compactMap({ $0 }) {
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(path)
        }
    }
    return result.sorted()
}
/// Preserve a requested Log row across an asynchronous reload. Navigation
/// resolves a full object id, while ordinary refreshes may only have a short
/// id from the existing selection, so keep the same exact-or-prefix matching
/// semantics in one testable helper.
func matchingLogCommitID(
    requestedID: String?,
    in commits: [CommitInfo]
) -> String? {
    guard let requestedID = requestedID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !requestedID.isEmpty else { return nil }
    if let exact = commits.first(where: { $0.id == requestedID }) {
        return exact.id
    }
    return commits.first(where: {
        $0.id.hasPrefix(requestedID) || requestedID.hasPrefix($0.id)
    })?.id
}
