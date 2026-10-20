import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {


struct BranchDashboardActionHandlers {
    let onFilterLog: (BranchDashboardReference) -> Void
    let onCompareWithCurrent: (BranchDashboardReference) -> Void
    let onShowDiffWithWorkingTree: (BranchDashboardReference) -> Void
    let onDeleteTag: (BranchDashboardReference) -> Void
    let onPushTag: (BranchDashboardReference) -> Void
    let onPushTagToRemote: (BranchDashboardReference, String) -> Void
    let tagPushRemotes: (BranchDashboardReference) -> [String]
    let trackedReference: (BranchDashboardReference) -> BranchDashboardReference?
    let onCompareSelected: ([BranchDashboardReference]) -> Void
    let onCompareSelectedFiles: ([BranchDashboardReference]) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onCheckout: (BranchDashboardReference) -> Void
    let onCheckoutAsNewBranch: (BranchDashboardReference) -> Void
    let onOpenWorktree: (BranchDashboardReference) -> Void
    let onCreateWorktreeFromReference: (BranchDashboardReference) -> Void
    let onCheckoutAndUpdate: (BranchDashboardReference) -> Void
    let onCheckoutWithRebase: (BranchDashboardReference) -> Void
    let onUpdate: (BranchDashboardReference) -> Void
    let onMerge: (BranchDashboardReference) -> Void
    let onRebase: (BranchDashboardReference) -> Void
    let onPush: (BranchDashboardReference) -> Void
    let onFetch: (BranchDashboardReference) -> Void
    let onPull: (BranchDashboardReference, Bool) -> Void
    let onSetUpstream: (BranchDashboardReference) -> Void
    let onUnsetUpstream: (BranchDashboardReference) -> Void
    let onRename: (BranchDashboardReference) -> Void
    let onDelete: (BranchDashboardReference) -> Void
    let onDeleteRemote: (BranchDashboardReference) -> Void
}


struct BranchDashboardActionMenu: View {
    let selection: [BranchDashboardReference]
    let handlers: BranchDashboardActionHandlers
    var allowsWorktreeAction = true

    var body: some View {
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let reference = selection.first

        Group {
            if let reference, availability.contains(.filterLog) {
                Button("Filter Log Here") {
                    handlers.onFilterLog(reference)
                }
            }
            if let reference, availability.contains(.compareWithCurrent) {
                Button("Compare with Current…") {
                    handlers.onCompareWithCurrent(reference)
                }
            }
            if let reference, availability.contains(.showDiffWithWorkingTree) {
                Button("Show Diff with Working Tree") {
                    handlers.onShowDiffWithWorkingTree(reference)
                }
            }
            if let reference,
               reference.kind == .local,
               reference.hasTracking,
               let tracked = handlers.trackedReference(reference) {
                Divider()
                Menu("Tracked Branch ((tracked.name))") {
                    AnyView(
                        BranchDashboardActionMenu(
                            selection: [tracked],
                            handlers: handlers,
                            allowsWorktreeAction: allowsWorktreeAction
                        )
                    )
                }
            }
            if let reference, availability.contains(.deleteTag) || availability.contains(.pushTag) {
                Divider()
                if availability.contains(.pushTag) {
                    let pushRemotes = handlers.tagPushRemotes(reference)
                    if pushRemotes.count > 1 {
                        Menu("Push Tag…") {
                            ForEach(pushRemotes, id: \.self) { remote in
                                Button(remote) {
                                    handlers.onPushTagToRemote(reference, remote)
                                }
                            }
                        }
                    } else {
                        Button("Push Tag…") {
                            handlers.onPushTag(reference)
                        }
                    }
                }
                if availability.contains(.deleteTag) {
                    Button("Delete Tag…", role: .destructive) {
                        handlers.onDeleteTag(reference)
                    }
                }
            }
            if availability.contains(.compareSelected), selection.count == 2 {
                Button("Compare Branches") {
                    handlers.onCompareSelected(selection)
                }
                .disabled(!availability.isEnabled(.compareSelected))
            }
            if availability.contains(.compareSelectedFiles), selection.count == 2 {
                Button("Show Files Diff") {
                    handlers.onCompareSelectedFiles(selection)
                }
                .disabled(!availability.isEnabled(.compareSelectedFiles))
            }

            if availability.contains(.updateSelected) {
                Button("Update Selected Branches") {
                    handlers.onUpdateSelected(selection)
                }
                .disabled(!availability.isEnabled(.updateSelected))
                .help(
                    availability.disabledDescription(for: .updateSelected)
                        ?? "Update Selected Branches"
                )
            }
            if availability.contains(.deleteSelected) {
                Button("Delete Selected Branches…", role: .destructive) {
                    handlers.onDeleteSelected(selection)
                }
                .disabled(!availability.isEnabled(.deleteSelected))
            }

            if availability.contains(.checkout)
                || availability.contains(.checkoutAsNewBranch)
                || (allowsWorktreeAction && availability.contains(.openWorktree))
                || availability.contains(.checkoutWithUpdate)
                || availability.contains(.checkoutWithRebase)
                || availability.contains(.update)
                || availability.contains(.merge)
                || availability.contains(.rebase)
                || (allowsWorktreeAction && availability.contains(.createWorktree))
                || availability.contains(.push)
                || availability.contains(.fetch)
                || availability.contains(.pull)
                || availability.contains(.pullWithRebase) {
                Divider()
            }
            if let reference, availability.contains(.checkout) {
                Button(reference.kind == .remote ? "Checkout as Local Branch" : "Checkout") {
                    handlers.onCheckout(reference)
                }
            }
            if let reference, availability.contains(.checkoutAsNewBranch) {
                Button(reference.kind == .head ? "New Branch from HEAD…" : "Checkout as New Branch…") {
                    handlers.onCheckoutAsNewBranch(reference)
                }
                .disabled(!availability.isEnabled(.checkoutAsNewBranch))
            }
            if let reference,
               allowsWorktreeAction,
               availability.contains(.openWorktree),
               reference.worktreePath != nil {
                Button("Open Worktree…") {
                    handlers.onOpenWorktree(reference)
                }
            }
            if let reference, availability.contains(.checkoutWithUpdate) {
                Button("Checkout and Update") {
                    handlers.onCheckoutAndUpdate(reference)
                }
                .disabled(!availability.isEnabled(.checkoutWithUpdate))
                .help(
                    availability.disabledDescription(for: .checkoutWithUpdate)
                        ?? "Checkout and Update"
                )
            }
            if let reference, availability.contains(.checkoutWithRebase) {
                Button("Checkout with Rebase") {
                    handlers.onCheckoutWithRebase(reference)
                }
                .disabled(!availability.isEnabled(.checkoutWithRebase))
            }
            if let reference, availability.contains(.update) {
                Button("Update") {
                    handlers.onUpdate(reference)
                }
                .disabled(!availability.isEnabled(.update))
                .help(
                    availability.disabledDescription(for: .update)
                        ?? "Update Branch"
                )
            }
            if let reference, availability.contains(.merge) {
                Button("Merge into Current…") {
                    handlers.onMerge(reference)
                }
            }
            if let reference, availability.contains(.rebase) {
                Button("Rebase Current onto…") {
                    handlers.onRebase(reference)
                }
            }
            if let reference,
               allowsWorktreeAction,
               availability.contains(.createWorktree) {
                Button(
                    reference.kind == .tag
                        ? "New Working Tree from Tag…"
                        : reference.kind == .head
                            ? "New Working Tree from HEAD…"
                            : "New Working Tree from Branch…"
                ) {
                    handlers.onCreateWorktreeFromReference(reference)
                }
                .disabled(!availability.isEnabled(.createWorktree))
            }
            if let reference, availability.contains(.push) {
                Button("Push…") {
                    handlers.onPush(reference)
                }
            }
            if let reference, availability.contains(.fetch) {
                Button("Fetch") {
                    handlers.onFetch(reference)
                }
            }
            if let reference, availability.contains(.pull), let localBranchName = reference.localBranchName {
                Button("Pull Local Branch (\(localBranchName))") {
                    handlers.onPull(reference, false)
                }
            }
            if let reference,
               availability.contains(.pullWithRebase),
               let localBranchName = reference.localBranchName {
                Button("Pull Local Branch (\(localBranchName)) with Rebase") {
                    handlers.onPull(reference, true)
                }
            }

            if let reference,
               availability.contains(.setUpstream) || availability.contains(.unsetUpstream) {
                Divider()
                if availability.contains(.setUpstream) {
                    Button("Set Upstream…") {
                        handlers.onSetUpstream(reference)
                    }
                }
                if availability.contains(.unsetUpstream) {
                    Button("Unset Upstream") {
                        handlers.onUnsetUpstream(reference)
                    }
                }
            }

            if let reference,
               availability.contains(.rename)
                || availability.contains(.deleteLocal)
                || availability.contains(.deleteRemote) {
                Divider()
                if availability.contains(.rename) {
                    Button("Rename Branch…") {
                        handlers.onRename(reference)
                    }
                }
                if availability.contains(.deleteLocal) {
                    Button("Delete Branch…", role: .destructive) {
                        handlers.onDelete(reference)
                    }
                }
                if availability.contains(.deleteRemote) {
                    Button("Delete Remote Branch…", role: .destructive) {
                        handlers.onDeleteRemote(reference)
                    }
                }
            }
        }
    }
}
}
