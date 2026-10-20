import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func multiRootRebaseSessionKey(projectPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.multiRootRebase.session.v1.\(encoded)"
}

func saveMultiRootRebaseSession(_ session: MultiRootRebaseSession) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    UserDefaults.standard.set(data, forKey: multiRootRebaseSessionKey(projectPath: session.projectPath))
}

func loadMultiRootRebaseSession(projectPath: String) -> MultiRootRebaseSession? {
    let key = multiRootRebaseSessionKey(projectPath: projectPath)
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(MultiRootRebaseSession.self, from: data)
}

func clearMultiRootRebaseSession(_ session: MultiRootRebaseSession) {
    UserDefaults.standard.removeObject(forKey: multiRootRebaseSessionKey(projectPath: session.projectPath))
}

func multiRootRebaseRows(for session: MultiRootRebaseSession) -> [RootOperationResult] {
    session.roots.map { root in
        switch root.state {
        case .pending:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: true,
                skipped: true,
                message: root.message.isEmpty ? "not attempted yet" : root.message
            )
        case .completed:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: true,
                skipped: false,
                message: root.message.isEmpty ? "rebase completed" : root.message
            )
        case .paused:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: true,
                skipped: false,
                message: root.message.isEmpty ? "rebase paused" : root.message
            )
        case .failed:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: false,
                skipped: false,
                message: root.message.isEmpty ? "rebase failed" : root.message
            )
        case .aborted:
            return RootOperationResult(
                rootPath: root.rootPath,
                displayName: root.displayName,
                success: false,
                skipped: false,
                message: root.message.isEmpty ? "rebase aborted" : root.message
            )
        }
    }
}

func multiRootRebaseFeedbackResultRows(
    for session: MultiRootRebaseSession
) -> [FeedbackResultRow] {
    let pausedRootPaths = Set(
        session.roots
            .filter { $0.state == .paused }
            .map(\.rootPath)
    )
    return feedbackResultRows(
        from: multiRootRebaseRows(for: session),
        partialRootPaths: pausedRootPaths
    )
}

func updateMultiRootRebaseSession(
    _ session: MultiRootRebaseSession,
    with results: [MultiRootRebaseResult]
) -> MultiRootRebaseSession {
    var updated = session
    for result in results {
        guard let index = updated.roots.firstIndex(where: { $0.rootPath == result.rootPath }) else { continue }
        var root = updated.roots[index]
        root.initialHead = result.initialHead ?? root.initialHead
        root.expectedHead = result.finalHead ?? root.expectedHead
        root.initialBranch = result.initialBranch ?? root.initialBranch
        root.message = result.message
        if result.skipped {
            updated.roots[index] = root
            continue
        }
        if result.requiresFinish {
            root.state = .paused
        } else if result.success && result.completed {
            root.state = .completed
        } else {
            root.state = .failed
        }
        updated.roots[index] = root
    }
    return updated
}

func multiRootRebaseRollbackTargets(
    for session: MultiRootRebaseSession,
    completedOnly: Bool = true
) -> [MultiRootRebaseRollbackTarget] {
    session.roots.compactMap { root -> MultiRootRebaseRollbackTarget? in
        guard (!completedOnly || root.state == .completed),
              let initialHead = root.initialHead,
              let expectedHead = root.expectedHead,
              initialHead != expectedHead else { return nil }
        return MultiRootRebaseRollbackTarget(
            rootPath: root.rootPath,
            displayName: root.displayName,
            initialHead: initialHead,
            expectedHead: expectedHead,
            branch: root.branch,
            protectionCommitID: root.protectionCommitID
        )
    }
}

}
