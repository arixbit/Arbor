import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// IntelliJ's Update Project dialog exposes RESET as a one-shot action rather
/// than as a persisted update method. Keep the same boundary here: only a
/// single checked-out branch with a configured upstream can use it.
func beginHeadResetDialog() {
    guard isArborVCSActionEnabled(.reset, in: vcsActionContext) else { return }
    let roots = resetHeadRootOptions
    guard !roots.isEmpty else { return }
    let defaultRootPath = repo?.workdir() ?? roots[0].path
    resetWorkspace.headRootPath = roots.first(where: {
        canonicalExternalLogPath($0.path) == canonicalExternalLogPath(defaultRootPath)
    })?.path ?? roots[0].path
    resetWorkspace.headTarget = "HEAD"
    let savedMode = GitResetModeSettings.mode(for: projectWorkspace.path).engineValue
    resetWorkspace.headMode = savedMode == .keep ? .mixed : savedMode
    resetWorkspace.showHeadDialog = true
}

func smartCheckoutRevisionInRoot(rootPath: String, revision: String) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Smart Checkout", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.smartCheckoutDetachedWithPolicyAndCancel(
                commitId: revision,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.feedbackCenter.success("Smart Checkout completed", detail: "\(revision) · \(rootPath)")
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Smart Checkout cancelled",
                        detail: "\(revision) · \(rootPath)",
                        nextStep: "The preservation Shelf was kept when restore had started; retry after reviewing the root."
                    )
                } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                    let viewAction = stashID.flatMap {
                        self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: $0,
                            rootPath: rootPath
                        )
                    }
                    var stashIndex = 0
                    if let stashID,
                       let rootRepo = try? openRepository(path: rootPath),
                       let index = try? rootRepo.stashList().firstIndex(where: { $0.id == stashID }) {
                        stashIndex = index
                    }
                    self.presentMultiRootStashConflict(
                        rootPath: rootPath,
                        index: stashIndex,
                        stashID: stashID,
                        isPop: true,
                        paths: paths,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: .shelf,
                        identifier: name,
                        rootPath: rootPath
                    )
                    self.presentMultiRootShelveConflict(
                        rootPath: rootPath,
                        name: name,
                        paths: paths,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                } else {
                    self.feedbackCenter.error(
                        "Smart Checkout failed",
                        detail: "\(revision) · \(rootPath): \(errorMessage(error))",
                        nextStep: "Resolve the root-specific restore conflict, then retry."
                    )
                }
            }
        }
    }
}

func forceCheckoutRevisionInRoot(rootPath: String, revision: String) {
    beginFeedbackOperation("Force Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.forceCheckoutDetached(commitId: revision)
            await MainActor.run {
                self.feedbackCenter.success("Force Checkout completed", detail: "\(revision) · \(rootPath)")
                self.loadMultiRoots()
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Force Checkout failed", detail: "\(revision) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

}
