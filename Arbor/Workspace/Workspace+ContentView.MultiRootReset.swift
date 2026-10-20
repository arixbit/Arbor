import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func runMultiRootResetOperation(
    projectPath: String,
    selectedRootPaths: [String],
    commitID: String? = nil,
    targetSpecs: [MultiRootResetTarget]? = nil,
    mode: ResetMode,
    smart: Bool,
    force: Bool,
    rootOrder: [String]? = nil,
    preservedResults: [RootOperationResult] = []
) {
    let operationRootPaths = selectedRootPaths
    let resultRootOrder = rootOrder ?? (
        operationRootPaths + preservedResults
            .map(\.rootPath)
            .filter { !operationRootPaths.contains($0) }
    )
    multiRootWorkspace.running = true
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation("Multi-root reset")
    Task.detached(priority: .userInitiated) {
        do {
            let results: [MultiRootResetResult]
            if let targetSpecs {
                results = try runMultiRootResetWithTargets(
                    scanRoot: projectPath,
                    targets: targetSpecs,
                    mode: mode,
                    savePolicy: projectSavePolicy,
                    smart: smart,
                    force: force
                )
            } else if let commitID {
                results = try runMultiRootResetWithPolicy(
                    scanRoot: projectPath,
                    selectedRootPaths: operationRootPaths,
                    commitId: commitID,
                    mode: mode,
                    savePolicy: projectSavePolicy,
                    smart: smart,
                    force: force
                )
            } else {
                throw NSError(
                    domain: "Arbor.Reset",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reset target is missing"]
                )
            }
            let operationResults = results.map { result in
                RootOperationResult(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    success: result.success,
                    skipped: result.skipped,
                    message: result.message
                )
            }
            let combinedOperationResults = mergeRootOperationResults(
                preserved: preservedResults,
                retry: operationResults,
                rootOrder: resultRootOrder
            )
            let overwriteFailures = results.filter {
                !$0.success && !$0.skipped && !$0.localChangesOverwritePaths.isEmpty
            }
            let failures = combinedOperationResults.filter { !$0.success || $0.skipped }
            let resetRecoveryTargets: [PersistedResetRecoveryTarget] = results.compactMap { result in
                guard result.success,
                      !result.skipped,
                      let initialHead = result.initialHead,
                      let expectedHead = result.finalHead,
                      let rollbackID = result.rollbackId else { return nil }
                return PersistedResetRecoveryTarget(
                    rootPath: result.rootPath,
                    displayName: result.displayName,
                    initialHead: initialHead,
                    expectedHead: expectedHead,
                    expectedHeadBranch: result.finalBranch,
                    mode: mode,
                    rollbackID: rollbackID
                )
            }
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.multiRootWorkspace.results = combinedOperationResults
                self.loadMultiRoots()
                if !overwriteFailures.isEmpty && !smart && !force {
                    let detail = overwriteFailures.map {
                        "\($0.displayName): \($0.localChangesOverwritePaths.joined(separator: ", "))"
                    }.joined(separator: "\n")
                    self.feedbackCenter.warning(
                        "Multi-root Reset needs a decision",
                        detail: detail,
                        nextStep: "Choose Smart Reset to preserve local changes in blocked roots, or cancel."
                    )
                    self.presentSmartOperationDecision(
                        operationTitle: "Multi-root Reset",
                        paths: overwriteFailures.flatMap { result in
                            result.localChangesOverwritePaths.map { "\(result.displayName): \($0)" }
                        },
                        detail: detail,
                        smartButtonTitle: "Smart Reset",
                        forceButtonTitle: mode == .hard ? "Force Reset" : nil,
                        onSmart: {
                            self.runMultiRootResetOperation(
                                projectPath: projectPath,
                                selectedRootPaths: overwriteFailures.map(\.rootPath),
                                commitID: commitID,
                                targetSpecs: targetSpecs?.filter { target in
                                    overwriteFailures.contains(where: { $0.rootPath == target.rootPath })
                                },
                                mode: mode,
                                smart: true,
                                force: false,
                                rootOrder: resultRootOrder,
                                preservedResults: combinedOperationResults.filter { result in
                                    !overwriteFailures.contains(where: { $0.rootPath == result.rootPath })
                                }
                            )
                        },
                        onForce: mode == .hard ? {
                            self.runMultiRootResetOperation(
                                projectPath: projectPath,
                                selectedRootPaths: overwriteFailures.map(\.rootPath),
                                commitID: commitID,
                                targetSpecs: targetSpecs?.filter { target in
                                    overwriteFailures.contains(where: { $0.rootPath == target.rootPath })
                                },
                                mode: mode,
                                smart: false,
                                force: true,
                                rootOrder: resultRootOrder,
                                preservedResults: combinedOperationResults.filter { result in
                                    !overwriteFailures.contains(where: { $0.rootPath == result.rootPath })
                                }
                            )
                        } : nil
                    )
                } else if failures.isEmpty {
                    let targetDetail = targetSpecs == nil
                        ? "target \(String((commitID ?? "").prefix(7)))"
                        : "one target per repository"
                    self.feedbackCenter.success(
                        "Multi-root Reset completed",
                        detail: "\(results.count) repositories · \(self.resetModeName(mode)) · \(targetDetail)",
                        additionalActions: self.resetRecoveryActions(
                            targets: resetRecoveryTargets
                        ),
                        notificationID: self.multiRootResetNotificationID(),
                        notificationGroup: .standard
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Multi-root Reset partially completed",
                        detail: failures.map {
                            "\($0.displayName): \($0.message.isEmpty ? ($0.skipped ? "skipped" : "failed") : $0.message)"
                        }.joined(separator: "\n"),
                        nextStep: "Review the affected Git roots and resolve any saved local-change restore marker.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            self.openMultiRootConflictResolver(preferredRootPath: failures.first?.rootPath)
                        },
                        additionalActions: self.resetRecoveryActions(
                            targets: resetRecoveryTargets
                        ),
                        notificationID: self.multiRootResetNotificationID(),
                        notificationGroup: .standard
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    "Multi-root Reset failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and target revision, then retry."
                )
            }
        }
    }
}

func multiRootResetNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-reset.\(stableProject)"
}

func resetRecoveryNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.reset-recovery.\(stableProject)"
}

}
