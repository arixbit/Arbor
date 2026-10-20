import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Import one or more portable unified/binary patches into the active Shelf.
/// The panel is intentionally kept as a small AppKit boundary; the engine
/// owns patch validation and isolated-index construction.
func applyPatchFromFile() {
    guard repo != nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Apply Patch"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
        let patch = try String(contentsOf: url, encoding: .utf8)
        presentApplyPatchRequest(fileName: url.lastPathComponent, patch: patch)
    } catch {
        feedbackCenter.error(
            "Patch apply failed",
            detail: errorMessage(error),
            nextStep: "Choose a UTF-8 unified or Git patch and try again."
        )
    }
}

/// Mirrors IntelliJ's ApplyPatchFromClipboardAction. Clipboard content enters
/// the same differentiated preview and conflict-recovery flow as a patch file;
/// it is never applied directly without path/hunk review.
func applyPatchFromClipboard() {
    guard repo != nil else { return }
    guard let patch = NSPasteboard.general.string(forType: .string),
          !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.error(
            "Patch apply failed",
            detail: "The clipboard does not contain text.",
            nextStep: "Copy a unified or Git patch and try again."
        )
        return
    }
    presentApplyPatchRequest(fileName: "Clipboard Patch", patch: patch)
}

func presentApplyPatchRequest(fileName: String, patch: String) {
    let files = RebasedUnshelveDialog.parsePatchFiles(patch, allowedPaths: [])
    let paths = files.map(\.path)
    guard !paths.isEmpty else {
        feedbackCenter.error(
            "Patch apply failed",
            detail: "The source does not contain a supported unified or Git patch.",
            nextStep: "Choose a valid patch source and try again."
        )
        return
    }
    fileWorkspace.pendingApplyPatch = RebasedApplyPatchRequest(
        fileName: fileName,
        patch: patch,
        paths: paths
    )
}

/// Apply a reviewed patch directly. This is the platform ApplyPatchAction
/// path: the patch is never inserted into the user's Shelf list, while its
/// conflict snapshot still uses the same restart-safe resolver lifecycle.
func applyImportedPatch(
    fileName: String,
    patch: String,
    paths: [String],
    selections: [ShelvePatchSelection],
    targetName: String?,
    basePath: String?,
    pathStrip: UInt32
) {
    guard let repo, !paths.isEmpty else { return }
    let operationName = "Apply Patch: \(fileName)"
    let mappedBasePath = basePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedTargetName = targetName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let mappedTargetName = trimmedTargetName?.isEmpty == true ? nil : trimmedTargetName
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Apply patch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            if let targetName = mappedTargetName,
               !(try repo.changelistList().contains(where: { $0.name == targetName })) {
                throw EngineError.GitOperation(message: "Target Changelist not found: \(targetName)")
            }
            let applyResult = try repo.applyImportedPatchDifferentiatedWithCancel(
                name: operationName,
                patch: patch,
                paths: paths,
                selections: selections,
                basePath: mappedBasePath,
                pathStrip: pathStrip,
                cancel: cancel
            )
            let appliedPaths = applyResult.appliedPaths
            let failedPaths = applyResult.failedPaths

            let status = try repo.status()
            let currentPaths = Set(status.map(\.path))
            let assignablePaths = appliedPaths.filter(currentPaths.contains)
            if let targetName = mappedTargetName {
                if !assignablePaths.isEmpty {
                    try repo.changelistMovePaths(paths: assignablePaths, targetName: targetName)
                }
            }
            await MainActor.run {
                self.repositoryStatus.entries = status
                self.repositoryStatus.changeLists = (try? repo.changelistList()) ?? self.repositoryStatus.changeLists
                self.refreshAfterShelfMutation(
                    repo: repo,
                    paths: appliedPaths
                )
                if applyResult.overallStatus == .abort {
                    self.feedbackCenter.warning(
                        "Patch apply aborted",
                        detail: "(fileName): no patch members were kept",
                        nextStep: "Retry Apply Patch when ready. The original worktree and index were restored."
                    )
                } else if !patchApplyNeedsAttention(applyResult) {
                    self.feedbackCenter.success(
                        "Patch applied",
                        detail: mappedTargetName.map { "\(fileName) → \($0)" } ?? fileName
                    )
                } else {
                    let targetDetail = mappedTargetName.map { " → \($0)" } ?? ""
                    self.feedbackCenter.warning(
                        "Patch partially applied",
                        detail: "\(fileName)\(targetDetail): \(patchApplySummary(applyResult, successDetail: "Applied", failureDetail: "Not applied"))\(failedPaths.isEmpty ? "" : " (\(failedPaths.joined(separator: ", ")))")",
                        nextStep: "Review the failed files and apply those patch members separately."
                    )
                }
            }
        } catch {
            if case let .ShelveApplyConflict(conflictName, conflictPaths) = error as? EngineError {
                let restoreInfo = (try? repo.shelveRestoreInfo()) ?? nil
                let patchText = restoreInfo?.patch ?? patch
                if let targetName = mappedTargetName {
                    _ = try? repo.shelveSetRestoreTarget(
                        name: conflictName,
                        targetChangeList: targetName
                    )
                }
                await MainActor.run {
                    self.presentShelveConflict(
                        name: conflictName,
                        paths: conflictPaths,
                        isPop: false,
                        changeListName: mappedTargetName,
                        isDirectPatch: true,
                        patchText: patchText
                    )
                }
            } else if let engineError = error as? EngineError, case .Cancelled = engineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Patch apply canceled",
                        detail: fileName,
                        nextStep: "The original worktree and index were kept. Retry Apply Patch when ready."
                    )
                }
            } else {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Patch apply failed",
                        detail: errorMessage(error),
                        nextStep: "The worktree was not left with a partial patch. Resolve the issue and retry."
                    )
                }
            }
        }
    }
}

nonisolated func patchApplyFeedbackState(
    _ result: PatchApplyResult
) -> FeedbackResultState {
    switch result.overallStatus {
    case .skip:
        .skipped
    case .failure:
        .failed
    case .abort:
        .aborted
    case .success, .alreadyApplied:
        .success
    case .partial:
        .partial
    }
}

nonisolated func patchApplyNeedsAttention(
    _ result: PatchApplyResult
) -> Bool {
    !result.failedPaths.isEmpty
        || result.overallStatus == .partial
        || result.overallStatus == .failure
        || result.overallStatus == .abort
}

nonisolated func patchApplySummary(
    _ result: PatchApplyResult,
    successDetail: String,
    failureDetail: String
) -> String {
    switch result.overallStatus {
    case .success:
        successDetail
    case .alreadyApplied:
        "Already applied"
    case .partial:
        "Partially applied: \(result.appliedPaths.count) applied, \(result.failedPaths.count) not applied"
    case .failure:
        failureDetail
    case .skip:
        "Not attempted"
    case .abort:
        "Aborted"
    }
}

}
