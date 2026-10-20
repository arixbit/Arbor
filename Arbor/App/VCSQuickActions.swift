import Foundation

/// The context-aware action list exposed by IntelliJ's
/// `GitQuickListContentProvider`. Keep this model separate from the larger
/// VCS menu: the quick list is intentionally short, searchable, and ordered
/// for keyboard use.
struct VCSQuickActionItem: Identifiable, Equatable {
    enum Section: String, CaseIterable, Hashable {
        case commit
        case repository
        case workspace
    }

    let action: ArborVCSAction
    let title: String
    let subtitle: String
    let systemImage: String
    let section: Section
    let isEnabled: Bool

    var id: String { action.rawValue }
}

func vcsQuickActionItems(
    isShallowRepository: Bool,
    hasCurrentBranch: Bool,
    hasConflicts: Bool,
    hasUnstagedTrackedChanges: Bool,
    hasUnstagedChanges: Bool,
    hasRepository: Bool = true,
    hasCommitChanges: Bool? = nil,
    hasFetchInProgress: Bool = false
) -> [VCSQuickActionItem] {
    var items = [
        VCSQuickActionItem(
            action: .commit,
            title: "Commit Changes…",
            subtitle: "Review staged and local changes before committing",
            systemImage: "checkmark.circle",
            section: .commit,
            isEnabled: hasRepository && (hasCommitChanges ?? hasUnstagedChanges)
        ),
        VCSQuickActionItem(
            action: .stageTracked,
            title: "Stage Changes",
            subtitle: "Stage tracked worktree changes before committing",
            systemImage: "arrow.right.circle",
            section: .commit,
            isEnabled: hasRepository && hasUnstagedTrackedChanges
        ),
        VCSQuickActionItem(
            action: .branches,
            title: "Branches…",
            subtitle: "Checkout, merge, rebase, pull, push, and branch management",
            systemImage: "arrow.triangle.branch",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .push,
            title: "Push…",
            subtitle: "Push the current root with refspec and lease options",
            systemImage: "arrow.up.circle",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .stash,
            title: "Stash…",
            subtitle: "Save local changes to Git's stash stack",
            systemImage: "archivebox",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .unstash,
            title: "Unstash Changes…",
            subtitle: "Apply or pop a selected stash",
            systemImage: "arrow.down.doc",
            section: .repository,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .worktrees,
            title: "Worktrees",
            subtitle: "Open, create, lock, unlock, prune, or remove worktrees",
            systemImage: "square.stack.3d.up",
            section: .workspace,
            isEnabled: hasRepository
        ),
        VCSQuickActionItem(
            action: .stageAll,
            title: "Stage All Changes",
            subtitle: "Stage tracked and untracked changes",
            systemImage: "arrow.right.to.line",
            section: .workspace,
            isEnabled: hasRepository && hasUnstagedChanges
        ),
        VCSQuickActionItem(
            action: .copyCurrentBranchName,
            title: "Copy Current Branch Name",
            subtitle: "Copy the current branch ref to the clipboard",
            systemImage: "doc.on.doc",
            section: .workspace,
            isEnabled: hasRepository && hasCurrentBranch
        ),
        VCSQuickActionItem(
            action: .resolveConflicts,
            title: "Resolve Conflicts",
            subtitle: "Open the Git root conflict resolver",
            systemImage: "exclamationmark.triangle",
            section: .workspace,
            isEnabled: hasRepository && hasConflicts
        )
    ]
    if isShallowRepository {
        items.append(
            VCSQuickActionItem(
                action: .fetchUnshallow,
                title: "Fetch Full History…",
                subtitle: "Convert this shallow clone into a complete history",
                systemImage: "arrow.down.to.line",
                section: .repository,
                isEnabled: hasRepository && !hasFetchInProgress
            )
        )
    }
    return items
}

func filteredVCSQuickActionItems(
    _ items: [VCSQuickActionItem],
    query: String
) -> [VCSQuickActionItem] {
    let tokens = query
        .split(whereSeparator: { $0.isWhitespace })
        .map { String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return items }
    return items.filter { item in
        let haystack = "\(item.title) \(item.subtitle)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
