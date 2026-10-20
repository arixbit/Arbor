import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
func rewordUndoNotificationID(
    rootPath: String,
    expectedHeadID: String
) -> String {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.reword-undo.\(normalizedRoot).\(expectedHeadID)"
}

func rewordUndoFeedbackAction(
    rootPath: String,
    context: PersistedRewordUndo
) -> FeedbackAction {
    let request = rewordUndoRequest(rootPath: rootPath, context: context)
    return FeedbackAction(
        id: "undo-reword:\(rootPath):\(context.expectedHeadID)",
        title: "Undo Reword Commit",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

/// Keep signing recovery on the same durable VCS notification as the failed
/// commit. The action is safe to replay after relaunch because it only opens
/// the settings surface; it never mutates Git state by itself.
func gpgAgentSettingsFeedbackAction() -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .openGpgAgentSettings,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: ""
    )
    return FeedbackAction(
        id: "open-gpg-agent-settings",
        title: "Configure GPG Agent…",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func beginFeedbackOperation(
    _ name: String,
    cancelHandle: GitCancelHandle? = nil,
    notificationID: String? = nil,
    preserveResultItems: Bool = false
) {
    feedbackCenter.begin(
        name,
        notificationID: notificationID,
        preserveResultItems: preserveResultItems,
        onCancel: cancelHandle.map { handle in
            { handle.cancel() }
        }
    )
}

/// Present the full IntelliJ-style Smart/Force/Cancel decision instead of
/// reducing an overwrite detector to a one-line retry toast.
func presentSmartOperationDecision(
    operationTitle: String,
    paths: [String],
    detail: String? = nil,
    smartButtonTitle: String,
    forceButtonTitle: String? = nil,
    onSmart: @escaping () -> Void,
    onForce: (() -> Void)? = nil
) {
    operationRecovery.smartOperationRequest = SmartOperationRequest(
        operationTitle: operationTitle,
        smartButtonTitle: smartButtonTitle,
        forceButtonTitle: forceButtonTitle,
        paths: paths,
        detail: detail,
        localChangesSavePolicy: GitLocalChangesSavePolicySettings.choice(for: projectWorkspace.path),
        onSmart: onSmart,
        onForce: onForce
    )
}

func runGitConsole(command: String, args: [String]) {
    guard let repo else { return }
    beginFeedbackOperation("Git Console")
    Task.detached(priority: .userInitiated) {
        do {
            let result = try repo.runGitCommand(command: command, args: args)
            await MainActor.run {
                self.operationRecovery.consoleResult = result
                self.feedbackCenter.recordGitCommand(result)
                if result.exitCode == 0 {
                    self.feedbackCenter.success("Git command completed", detail: result.command)
                } else {
                    self.feedbackCenter.error(
                        "Git command failed",
                        detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                        nextStep: "Review stderr in Git Console and retry after fixing the command."
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Git Console failed", detail: errorMessage(error))
            }
        }
    }
}

/// 在当前窗口加载单个项目，并丢弃上一项目的所有选择和缓存。
func expireOperationRecoveryNotifications() {
    for rootPath in operationRecovery.notificationFingerprints.keys {
        feedbackCenter.expire(
            notificationID: operationRecoveryNotificationID(rootPath: rootPath)
        )
    }
    operationRecovery.notificationFingerprints.removeAll()
}

nonisolated func logSelectedChangesUndoNotificationID(
    repositoryPath: String,
    expectedHead: String
) -> String {
    let stablePath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.log-selected-changes-undo.\(stablePath).\(expectedHead)"
}

func logSelectedChangesUndoFeedbackAction(
    for target: LogSelectedChangesUndoTarget
) -> FeedbackAction {
    let request = logSelectedChangesUndoRequest(for: target)
    return FeedbackAction(
        id: "undo-log-selected-changes:\(target.repositoryPath):\(target.expectedHead)",
        title: "Undo Selected Changes",
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

func showOperationDetailsAction(notificationID: String) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .showOperationDetails,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        operationNotificationID: notificationID
    )
    return FeedbackAction(title: "Show Details", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

}
