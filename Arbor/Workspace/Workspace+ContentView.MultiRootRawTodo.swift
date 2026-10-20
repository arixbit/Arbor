import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Capture the native todo for one repository in the multi-root editor. The
/// branch is explicit because the batch may target a branch that is not the
/// currently checked-out branch in that root.
func prepareMultiRootRawTodoEditor(_ draft: MultiRootRebaseTodoDraft) {
    guard draft.loadError == nil else { return }
    let onto = rebaseWorkspace.onto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseWorkspace.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let preserveMerges = rebaseWorkspace.preserveMerges
    let autoSquash = rebaseWorkspace.autoSquash
    let keepEmpty = rebaseWorkspace.keepEmpty
    let updateRefs = rebaseWorkspace.updateRefs
    let rootMode = rebaseWorkspace.root
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    if let rawTodo = draft.rawTodo {
        rebaseWorkspace.multiRootRawTodoText = rawTodo
        rebaseWorkspace.multiRootRawTodoContext = MultiRootRawTodoContext(
            rootPath: draft.rootPath,
            displayName: draft.displayName,
            onto: onto,
            preserveMerges: preserveMerges,
            root: rootMode
        )
        return
    }

    let cancel = GitCancelHandle()
    beginFeedbackOperation(
        "Prepare Native Todo · \(draft.displayName)",
        cancelHandle: cancel
    )
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: draft.rootPath)
            let rawTodo = try rootRepo.rebaseRawTodoForBranchWithOptionsAndPolicyAndCancel(
                onto: onto,
                branch: branch,
                preserveMerges: preserveMerges,
                autoSquash: autoSquash,
                keepEmpty: keepEmpty,
                updateRefs: updateRefs,
                root: rootMode,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.rebaseWorkspace.multiRootRawTodoText = rawTodo
                self.rebaseWorkspace.multiRootRawTodoContext = MultiRootRawTodoContext(
                    rootPath: draft.rootPath,
                    displayName: draft.displayName,
                    onto: onto,
                    preserveMerges: preserveMerges,
                    root: rootMode
                )
                self.feedbackCenter.success(
                    "Native todo ready",
                    detail: draft.displayName + " · control rows remain editable"
                )
            }
        } catch {
            await MainActor.run {
                if case .Cancelled = error as? EngineError {
                    self.feedbackCenter.warning(
                        "Native todo preparation cancelled",
                        detail: draft.displayName,
                        nextStep: "The local scene was restored; reopen the native todo editor to retry."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Prepare native todo failed",
                        detail: draft.displayName + ": " + errorMessage(error),
                        nextStep: "The root must be free of another Git operation; retry after refreshing."
                    )
                }
            }
        }
    }
}

/// Store the text edited for one root without starting the batch yet. Other
/// roots remain structured or raw independently in the same editor.
func finishMultiRootRawTodoEditor(_ context: MultiRootRawTodoContext) {
    let rawTodo = rebaseWorkspace.multiRootRawTodoText
    guard !rawTodo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let index = rebaseWorkspace.multiRootDrafts.firstIndex(where: { $0.rootPath == context.rootPath }) else {
        return
    }
    rebaseWorkspace.multiRootDrafts[index].rawTodo = rawTodo
    rebaseWorkspace.multiRootRawTodoContext = nil
    rebaseWorkspace.multiRootRawTodoText = ""
}

}
