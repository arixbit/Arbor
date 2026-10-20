import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func viewDeletedBranchCommitsFromSemanticTargets(
    _ targets: [PersistedBranchDeleteRecoveryTarget]
) {
    guard let normalizedTargets = normalizedBranchDeleteRecoveryTargets(targets) else { return }
    var contexts: [BranchDeleteRecoveryContext] = []
    for target in normalizedTargets {
        guard let rootRepo = try? openRepository(path: target.rootPath) else {
            feedbackCenter.error(
                "View deleted commits unavailable",
                detail: "The Git root could not be opened: \(target.rootPath)",
                nextStep: "Refresh Git Roots, then retry the notification action."
            )
            return
        }
        let preview = BranchDeletePreview(
            branchName: target.branchName,
            tipId: target.tipID,
            upstream: target.upstream,
            baseBranches: target.baseBranches,
            unmergedCommits: target.unmergedCommits.map {
                BranchDeleteCommit(
                    id: $0.id,
                    shortId: $0.shortID,
                    summary: $0.summary,
                    time: $0.time
                )
            }
        )
        contexts.append(
            BranchDeleteRecoveryContext(
                repo: rootRepo,
                preview: preview,
                rootPath: target.rootPath
            )
        )
    }
    guard !contexts.isEmpty else { return }
    branchWorkspace.deleteRecovery = nil
    branchWorkspace.multiRootDeleteRecovery = nil
    if contexts.count == 1 {
        branchWorkspace.deleteRecovery = contexts[0]
    } else {
        let branchNames = Array(Set(contexts.map { $0.preview.branchName })).sorted()
        branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
            branchName: branchNames.joined(separator: ", "),
            contexts: contexts
        )
    }
}

nonisolated static func updatedCommitCount(from updateMessage: String) -> Int? {
    let words = updateMessage.split(whereSeparator: { $0 == " " || $0 == "\n" })
    guard let index = words.firstIndex(where: { $0.caseInsensitiveCompare("updated") == .orderedSame }),
          index < words.index(before: words.endIndex) else {
        return nil
    }
    return Int(words[words.index(after: index)])
}

nonisolated static func headCommitIDs(for rootPaths: [String]) -> [String: String] {
    var heads: [String: String] = [:]
    for rootPath in rootPaths {
        guard let rootRepo = try? openRepository(path: rootPath),
              let head = rootRepo.headCommitId(),
              !head.isEmpty else { continue }
        heads[rootPath] = head
    }
    return heads
}

func multiRootUpdateViewCommitsAction(
    ranges: [PersistedLogRevisionRange]
) -> FeedbackAction? {
    guard !ranges.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showLogRanges,
        projectPath: projectWorkspace.path,
        rootPath: ranges.count == 1 ? ranges[0].rootPath : nil,
        shelfName: "",
        logRevisionRanges: ranges
    )
    return FeedbackAction(title: "View Commits", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func branchDeleteViewCommitsAction(
    contexts: [BranchDeleteRecoveryContext]
) -> FeedbackAction? {
    guard contexts.contains(where: { !$0.preview.unmergedCommits.isEmpty }),
          let targets = branchDeleteRecoveryTargets(from: contexts) else {
        return nil
    }
    let request = ArborVCSActionRequest(
        kind: .viewDeletedBranchCommits,
        projectPath: projectWorkspace.path,
        rootPath: targets.count == 1 ? targets[0].rootPath : nil,
        shelfName: "",
        branchDeleteRecoveryTargets: targets
    )
    return FeedbackAction(title: "View Commits", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

}
