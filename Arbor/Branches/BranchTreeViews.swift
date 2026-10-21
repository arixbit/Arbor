import SwiftUI

struct BranchDirectoryGroupRow: View {
    enum Style {
        case popup
        case log
    }

    let row: BranchDirectoryRow
    @Binding var collapsedGroups: Set<String>
    let style: Style

    var body: some View {
        Button {
            if collapsedGroups.contains(row.id) {
                collapsedGroups.remove(row.id)
            } else {
                collapsedGroups.insert(row.id)
            }
        } label: {
            Label(
                row.name,
                systemImage: collapsedGroups.contains(row.id) ? "chevron.right" : "chevron.down"
            )
            .font(style == .popup ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(row.depth) * 14 + (style == .popup ? 6 : 0))
            .padding(.top, style == .popup ? 4 : 0)
        }
        .buttonStyle(.plain)
    }
}

struct BranchDashboardRemoteGroupActionMenu: View {
    let selection: [BranchDashboardRemoteGroup]
    let onEditRemote: (String, String) -> Void
    let onRemoveRemote: (String, String) -> Void
    let onRemoveRemoteSelected: ([BranchDashboardRemoteGroup]) -> Void

    var body: some View {
        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: selection)
        if availability.contains(.editRemote), let group = selection.first {
            Button("Edit Remote…") {
                onEditRemote(group.rootPath, group.name)
            }
        }
        if availability.contains(.removeRemote) {
            if availability.contains(.editRemote) {
                Divider()
            }
            Button(
                selection.count == 1 ? "Remove Remote…" : "Remove Selected Remotes…",
                role: .destructive
            ) {
                if selection.count == 1, let group = selection.first {
                    onRemoveRemote(group.rootPath, group.name)
                } else {
                    onRemoveRemoteSelected(selection)
                }
            }
        }
    }
}

func branchRemoteGroupNames(_ snapshot: GitRootBranchSnapshot) -> [String] {
    var names = snapshot.remotes.map(\.name)
    for remote in snapshot.remoteBranches.map(\.remote) where !names.contains(remote) {
        names.append(remote)
    }
    return names.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }
}
