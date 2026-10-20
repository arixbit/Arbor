import SwiftUI
import AppKit
import UniformTypeIdentifiers


func logChangesCommitRecords(
    _ records: [LogChangeRecord],
    for commit: CommitInfo
) -> [LogChangeRecord] {
    let identity = logChangesCommitIdentity(commit)
    return records.filter {
        logChangesCommitIdentity($0.commit) == identity
    }
}

func logChangesCommitGroupName(
    _ commit: CommitInfo,
    among commits: [CommitInfo]
) -> String {
    let rootPath = commit.repositoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootName = rootPath.map {
        URL(fileURLWithPath: $0).lastPathComponent
    }.flatMap { $0.isEmpty ? nil : $0 }
    let hasAmbiguousRootName = rootName.map { name in
        commits.compactMap { other in
            other.repositoryPath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
        }.filter { $0 == name }.count > 1
    } ?? false
    let displayRoot = hasAmbiguousRootName ? rootPath : rootName
    let commitTitle = "\(commit.shortId)  \(commit.summary)"
    return displayRoot.map { "\($0) · \(commitTitle)" } ?? commitTitle
}
