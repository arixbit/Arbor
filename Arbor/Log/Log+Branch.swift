import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Match IntelliJ's BranchesDashboardTreeSelection.selectedBranchFilters:
/// branches (including remote branches) and HEAD participate in a branch
/// filter, while tags remain navigable refs but are not branch filters.
func logBranchFiltersForDashboardSelection(
    _ selection: [BranchDashboardReference]
) -> [LogRootBranchFilter] {
    var seen = Set<LogRootBranchFilter>()
    return selection.compactMap { reference in
        guard reference.kind == .head
            || reference.kind == .local
            || reference.kind == .remote else {
            return nil
        }
        let filter = LogRootBranchFilter(
            rootPath: reference.rootPath,
            branch: reference.name
        )
        return seen.insert(filter).inserted ? filter : nil
    }
}

enum LogBranchesGroupingMode: Equatable {
    case repository
    case refKind
}

/// Mirrors IntelliJ's GroupBranchByRepositoryAction visibility and toggle.
/// The repository grouping control is meaningful only for a multi-root Log
/// dashboard; single-root views remain grouped by ref kind internally.
func logBranchesGroupingMode(
    repositoryCount: Int,
    groupByRepository: Bool
) -> LogBranchesGroupingMode {
    repositoryCount > 1 && groupByRepository ? .repository : .refKind
}
