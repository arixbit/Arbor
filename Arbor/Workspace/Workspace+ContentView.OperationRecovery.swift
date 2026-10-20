import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func operationRecoveryKindTitle(_ kind: OperationKind) -> String {
    switch kind {
    case .merge: return "Merge"
    case .rebase: return "Rebase"
    case .cherryPick: return "Cherry-pick"
    case .revert: return "Revert"
    }
}

func operationRecoveryActionTitle(
    _ action: ArborVCSActionRequest.OperationRecoveryAction
) -> String {
    switch action {
    case .continueOperation: return "Continue"
    case .skip: return "Skip"
    case .abort: return "Abort"
    case .openRecovery: return "Open Recovery"
    }
}

func operationRecoveryRequest(
    action: ArborVCSActionRequest.OperationRecoveryAction,
    projectPath: String?,
    rootPath: String
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .operationRecovery,
        projectPath: projectPath,
        rootPath: rootPath,
        shelfName: "",
        operationRecoveryAction: action
    )
}

func operationRecoveryFeedbackAction(
    _ action: ArborVCSActionRequest.OperationRecoveryAction,
    projectPath: String?,
    rootPath: String
) -> FeedbackAction {
    let request = operationRecoveryRequest(
        action: action,
        projectPath: projectPath,
        rootPath: rootPath
    )
    return FeedbackAction(
        title: operationRecoveryActionTitle(action),
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func operationRecoveryFeedbackActions(
    state: OperationState,
    rootPath: String
) -> [FeedbackAction] {
    var actions = [
        operationRecoveryFeedbackAction(
            .continueOperation,
            projectPath: projectWorkspace.path,
            rootPath: rootPath
        )
    ]
    if state.kind == .rebase {
        actions.append(
            operationRecoveryFeedbackAction(
                .skip,
                projectPath: projectWorkspace.path,
                rootPath: rootPath
            )
        )
    }
    actions.append(
        operationRecoveryFeedbackAction(
            .abort,
            projectPath: projectWorkspace.path,
            rootPath: rootPath
        )
    )
    actions.append(
        operationRecoveryFeedbackAction(
            .openRecovery,
            projectPath: projectWorkspace.path,
            rootPath: rootPath
        )
    )
    return actions
}

func publishOperationRecoveryNotice(
    state: OperationState,
    rootPath: String
) -> Bool {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let hasDedicatedRebaseRecovery = state.kind == .rebase
        && (
            loadRebaseUndoSeed(repositoryPath: normalizedRoot) != nil
                || rebaseWorkspace.multiRootSession?.roots.contains(where: {
                    URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path == normalizedRoot
                }) == true
        )
    guard !hasDedicatedRebaseRecovery else { return false }
    let kindTitle = operationRecoveryKindTitle(state.kind)
    let detail: String
    if state.conflictedFiles.isEmpty {
        detail = "A \(kindTitle) operation is paused in this repository."
    } else {
        detail = "\(state.conflictedFiles.count) conflicted file(s) must be resolved before continuing."
    }
    feedbackCenter.warning(
        "\(kindTitle) recovery available",
        detail: detail,
        nextStep: "Continue, Skip, or Abort the operation from the recovery actions.",
        additionalActions: operationRecoveryFeedbackActions(
            state: state,
            rootPath: rootPath
        ),
        notificationID: operationRecoveryNotificationID(rootPath: rootPath),
        notificationGroup: .important,
        localized: false
    )
    return true
}

func publishOperationRecoveryNoticeIfNeeded(
    state: OperationState,
    rootPath: String
) {
    let key = operationRecoveryNotificationRootKey(rootPath)
    let fingerprint = operationRecoveryNotificationFingerprint(state)
    guard operationRecovery.notificationFingerprints[key] != fingerprint else { return }
    if publishOperationRecoveryNotice(state: state, rootPath: rootPath) {
        operationRecovery.notificationFingerprints[key] = fingerprint
    }
}

func openOperationRecovery(rootPath: String, preferredPath: String? = nil) {
    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    let currentRootMatches = repo?.workdir().map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
            == URL(fileURLWithPath: rootPath).standardizedFileURL.path
    } == true
    guard currentRootMatches else {
        openMultiRootConflictResolver(
            preferredRootPath: rootPath,
            preferredPath: preferredPath
        )
        return
    }
    if let preferredPath {
        operationRecovery.initialPath = preferredPath
        fileWorkspace.selection = preferredPath
    } else if let conflictPath = operationRecovery.operation?.conflictedFiles.first {
        operationRecovery.initialPath = conflictPath
        fileWorkspace.selection = conflictPath
    }
    if let state = operationRecovery.operation, !state.conflictedFiles.isEmpty {
        openMultiRootConflictResolver(
            preferredRootPath: rootPath,
            preferredPath: preferredPath ?? state.conflictedFiles.first
        )
    }
}

}
