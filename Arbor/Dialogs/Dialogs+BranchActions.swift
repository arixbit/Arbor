import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// IntelliJ's `Git.Branches.List` action group contributes these actions to
/// the branch tree's speed search.  The remaining branch operations stay in
/// the popup footer or on reference context menus, so they are intentionally
/// not treated as speed-search results here.
enum BranchPopupActionID: String, CaseIterable, Identifiable {
    case commitChanges
    case newBranch
    case checkoutReference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commitChanges: "Commit Changes…"
        case .newBranch: "New Branch…"
        case .checkoutReference: "Checkout Tag or Revision…"
        }
    }

    var systemImage: String {
        switch self {
        case .commitChanges: "checkmark.circle"
        case .newBranch: "plus"
        case .checkoutReference: "arrow.down.to.line"
        }
    }
}
/// IntelliJ's `Git.Ongoing.Rebase.Actions` is a non-popup action group that
/// is injected at the top of `Git.Branches.List`. Keep the action IDs here so
/// the popup can preserve the same ordering and route recovery operations
/// without guessing from localized titles.
enum BranchPopupOperationActionID: String, CaseIterable, Identifiable {
    case abortRebase = "Git.Rebase.Abort"
    case mergeCommit = "Git.Merge.Commit"
    case mergeAbort = "Git.Merge.Abort"
    case cherryPickAbort = "Git.CherryPick.Abort"
    case cherryPickContinue = "Git.CherryPick.Continue"
    case revertAbort = "Git.Revert.Abort"
    case rebaseContinue = "Git.Rebase.Continue"
    case rebaseSkip = "Git.Rebase.Skip"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .abortRebase: "Abort Rebase"
        case .mergeCommit: "Commit Merge"
        case .mergeAbort: "Abort Merge"
        case .cherryPickAbort: "Abort Cherry-Pick"
        case .cherryPickContinue: "Continue Cherry-Pick"
        case .revertAbort: "Abort Revert"
        case .rebaseContinue: "Continue Rebase"
        case .rebaseSkip: "Skip Commit"
        }
    }

    var systemImage: String {
        switch self {
        case .abortRebase, .mergeAbort, .cherryPickAbort, .revertAbort:
            "xmark.circle"
        case .cherryPickContinue, .mergeCommit, .rebaseContinue:
            "arrow.right.circle"
        case .rebaseSkip:
            "forward.end"
        }
    }

    var recoveryAction: ArborVCSActionRequest.OperationRecoveryAction {
        switch self {
        case .mergeCommit, .rebaseContinue, .cherryPickContinue:
            .continueOperation
        case .rebaseSkip:
            .skip
        case .abortRebase, .mergeAbort, .cherryPickAbort, .revertAbort:
            .abort
        }
    }

    static func actions(for kind: OperationKind) -> [Self] {
        switch kind {
        case .merge:
            [.mergeAbort]
        case .rebase:
            [.abortRebase, .rebaseContinue, .rebaseSkip]
        case .cherryPick:
            [.cherryPickAbort, .cherryPickContinue]
        case .revert:
            [.revertAbort]
        }
    }

    /// IntelliJ hides Cherry-Pick Continue while the conflict resolver owns
    /// the flow. The abort action remains available, matching the reference
    /// action update rules.
    var isVisibleWithConflicts: Bool {
        self != .cherryPickContinue && self != .mergeCommit
    }
}
func branchPopupOperationActions(
    for kind: OperationKind,
    hasConflicts: Bool
) -> [BranchPopupOperationActionID] {
    BranchPopupOperationActionID.actions(for: kind)
        .filter { $0.isVisibleWithConflicts || !hasConflicts }
}
struct BranchPopupOperationContext: Identifiable, Equatable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let kind: OperationKind
    let hasConflicts: Bool

    var id: String { rootPath }
}
func filteredBranchPopupActions(
    _ actions: [BranchPopupActionID] = BranchPopupActionID.allCases,
    query: String,
    filterByAction: Bool
) -> [BranchPopupActionID] {
    guard filterByAction else { return [] }
    return actions.filter { branchSearchMatches($0.title, query: query) }
}
func branchPopupVisibleActions(
    _ actions: [BranchPopupActionID] = BranchPopupActionID.allCases,
    query: String,
    filterByAction: Bool
) -> [BranchPopupActionID] {
    filterByAction
        ? filteredBranchPopupActions(actions, query: query, filterByAction: true)
        : actions
}
/// GitCreateNewBranchAction stays visible but disabled for a fresh/unborn
/// repository because its top-level action always starts from HEAD.
func isBranchPopupActionEnabled(
    _ action: BranchPopupActionID,
    hasHeadCommit: Bool,
    hasCommitChanges: Bool = true
) -> Bool {
    switch action {
    case .commitChanges:
        return hasCommitChanges
    case .newBranch:
        return hasHeadCommit
    case .checkoutReference:
        return true
    }
}
func branchPopupActionDisabledDescription(
    _ action: BranchPopupActionID,
    hasHeadCommit: Bool,
    hasCommitChanges: Bool = true
) -> String? {
    switch action {
    case .commitChanges where !hasCommitChanges:
        return "There are no Git changes to commit"
    case .newBranch where !hasHeadCommit:
        return "Cannot create new branch in empty repository. Make initial commit first"
    default:
        return nil
    }
}
/// The Log branch dashboard keeps local and remote references separate from
/// the repository that owns them.  The action group must use the same scope;
/// otherwise a same-named branch in another Git root can execute against the
/// window's active repository.
enum BranchDashboardReferenceKind: String, Hashable, Sendable {
    case head
    case local
    case remote
    case tag
}
struct BranchDashboardReference: Hashable, Sendable {
    let rootPath: String
    let name: String
    let kind: BranchDashboardReferenceKind
    let remote: String?
    let localBranchName: String?
    let isCurrent: Bool
    let hasUpstream: Bool
    let hasTracking: Bool
    let hasRemote: Bool
    let isProtected: Bool
    let hasHeadCommit: Bool
    let worktreePath: String?
    /// The named branch behind the synthetic HEAD row. IntelliJ resolves a
    /// HEAD + branch selection to this name before invoking GitBrancher.
    let headBranchName: String?

    static func referenceID(
        rootPath: String,
        name: String,
        kind: BranchDashboardReferenceKind
    ) -> String {
        kind.rawValue + ":" + rootPath + ":" + name
    }

    var favoriteID: String {
        Self.referenceID(rootPath: rootPath, name: name, kind: kind)
    }

    init(
        rootPath: String,
        name: String,
        kind: BranchDashboardReferenceKind,
        remote: String?,
        localBranchName: String? = nil,
        isCurrent: Bool,
        hasUpstream: Bool,
        hasTracking: Bool,
        hasRemote: Bool,
        isProtected: Bool,
        hasHeadCommit: Bool = true,
        worktreePath: String? = nil,
        headBranchName: String? = nil
    ) {
        self.rootPath = rootPath
        self.name = name
        self.kind = kind
        self.remote = remote
        self.localBranchName = localBranchName
        self.isCurrent = isCurrent
        self.hasUpstream = hasUpstream
        self.hasTracking = hasTracking
        self.hasRemote = hasRemote
        self.isProtected = isProtected
        self.hasHeadCommit = hasHeadCommit
        self.worktreePath = worktreePath
        self.headBranchName = headBranchName
    }
}
enum BranchDashboardAction: String, Hashable, Sendable {
    case filterLog
    case compareWithCurrent
    case showDiffWithWorkingTree
    case deleteTag
    case pushTag
    case compareSelected
    case compareSelectedFiles
    case checkout
    case checkoutAsNewBranch
    case openWorktree
    case createWorktree
    case checkoutWithUpdate
    case checkoutWithRebase
    case update
    case updateSelected
    case merge
    case rebase
    case push
    case fetch
    case pull
    case pullWithRebase
    case setUpstream
    case unsetUpstream
    case rename
    case deleteLocal
    case deleteSelected
    case deleteRemote
}
struct BranchDashboardActionAvailability: Equatable, Sendable {
    let actions: Set<BranchDashboardAction>
    let disabledActions: Set<BranchDashboardAction>

    init(
        actions: Set<BranchDashboardAction>,
        disabledActions: Set<BranchDashboardAction> = []
    ) {
        self.actions = actions
        self.disabledActions = disabledActions
    }

    func contains(_ action: BranchDashboardAction) -> Bool {
        actions.contains(action)
    }

    func isEnabled(_ action: BranchDashboardAction) -> Bool {
        contains(action) && !disabledActions.contains(action)
    }

    func disabledDescription(for action: BranchDashboardAction) -> String? {
        guard disabledActions.contains(action) else { return nil }
        switch action {
        case .checkoutWithUpdate:
            return "Checkout and Update is unavailable because the branch is either not tracking a remote branch or is checked out in another worktree."
        case .update, .updateSelected:
            return "Update is unavailable because the branch is either not tracking a remote branch or is checked out in another worktree."
        default:
            return nil
        }
    }

    /// Mirrors the useful part of IntelliJ's BranchesDashboardActions:
    /// one reference gets the complete single-ref group, while mixed or
    /// multi-root selections fail closed instead of guessing a repository.
    static func resolve(
        selection: [BranchDashboardReference]
    ) -> BranchDashboardActionAvailability {
        guard let reference = selection.first else {
            return BranchDashboardActionAvailability(actions: [])
        }

        if selection.count > 1 {
            var actions: Set<BranchDashboardAction> = []
            var disabledActions: Set<BranchDashboardAction> = []
            if selection.count == 2,
               selection.allSatisfy({ $0.kind != .tag }) {
                actions.insert(.compareSelected)
                actions.insert(.compareSelectedFiles)
                if branchDashboardComparisonPair(selection: selection) == nil {
                    disabledActions.insert(.compareSelected)
                    disabledActions.insert(.compareSelectedFiles)
                }
            }
            if selection.allSatisfy({ $0.kind == .local }),
               selection.allSatisfy({ $0.hasTracking }) {
                actions.insert(.updateSelected)
                if selection.contains(where: { $0.worktreePath != nil }) {
                    disabledActions.insert(.updateSelected)
                }
            }
            let hasOnlyTags = selection.allSatisfy { $0.kind == .tag }
            let hasOnlyDeletableRefs = selection.allSatisfy { $0.kind != .tag && $0.kind != .head }
            if hasOnlyTags || hasOnlyDeletableRefs {
                actions.insert(.deleteSelected)
                if selection.contains(where: { $0.isCurrent || $0.isProtected }) {
                    disabledActions.insert(.deleteSelected)
                }
            }
            return BranchDashboardActionAvailability(
                actions: actions,
                disabledActions: disabledActions
            )
        }

        var actions: Set<BranchDashboardAction> = [
            .filterLog,
            .showDiffWithWorkingTree
        ]
        var disabledActions: Set<BranchDashboardAction> = []
        switch reference.kind {
        case .head:
            actions.formUnion([.checkoutAsNewBranch, .createWorktree])
            if !reference.hasHeadCommit {
                disabledActions.insert(.checkoutAsNewBranch)
                disabledActions.insert(.createWorktree)
            }
            if reference.worktreePath != nil {
                actions.insert(.openWorktree)
            }
        case .local:
            actions.insert(.compareWithCurrent)
            actions.formUnion([.checkoutAsNewBranch, .createWorktree, .rename])
            if reference.worktreePath != nil {
                actions.insert(.openWorktree)
            }
            if !reference.isCurrent {
                actions.formUnion([.checkout, .checkoutWithRebase, .merge, .rebase, .deleteLocal])
                if reference.worktreePath != nil {
                    disabledActions.insert(.checkout)
                }
                if reference.hasRemote {
                    actions.insert(.checkoutWithUpdate)
                    if !reference.hasTracking || reference.worktreePath != nil {
                        disabledActions.insert(.checkoutWithUpdate)
                    }
                }
                if reference.worktreePath != nil {
                    disabledActions.insert(.checkoutWithRebase)
                }
            }
            if reference.hasRemote {
                actions.insert(.update)
                if !reference.hasTracking || reference.worktreePath != nil {
                    disabledActions.insert(.update)
                }
            }
            if !reference.hasHeadCommit {
                disabledActions.insert(.checkoutAsNewBranch)
                disabledActions.insert(.createWorktree)
            }
            if reference.hasUpstream {
                actions.insert(.unsetUpstream)
            } else if reference.hasRemote {
                actions.insert(.setUpstream)
            }
            // GitPushBranchAction only disables remote refs; it remains
            // visible for a local branch even when no remote is configured.
            actions.insert(.push)
        case .remote:
            actions.insert(.compareWithCurrent)
            actions.formUnion([
                .checkout,
                .checkoutAsNewBranch,
                .checkoutWithRebase,
                .merge,
                .rebase,
                .fetch,
                .pull,
                .pullWithRebase
            ])
            actions.insert(.deleteRemote)
            if reference.isProtected {
                disabledActions.insert(.deleteRemote)
            }
        case .tag:
            actions.insert(.compareWithCurrent)
            if !reference.isCurrent {
                actions.formUnion([
                    .checkout,
                    .merge,
                    .deleteTag
                ])
            }
            if reference.hasRemote {
                actions.insert(.pushTag)
            }
        }

        if reference.isCurrent || reference.kind == .tag || reference.kind == .head {
            actions.remove(.compareWithCurrent)
        }
        return BranchDashboardActionAvailability(
            actions: actions,
            disabledActions: disabledActions
        )
    }
}
