import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// IntelliJ keeps Git.Merge.Commit in Git.MainMenu.MergeActions. It is not
/// part of Git.Ongoing.Rebase.Actions, which is the operation group injected
/// into the Branches Popup.
func gitMainMenuOperationActions(
    for kind: OperationKind,
    hasConflicts: Bool
) -> [BranchPopupOperationActionID] {
    let actions: [BranchPopupOperationActionID] = switch kind {
    case .merge:
        [.mergeCommit, .mergeAbort]
    default:
        branchPopupOperationActions(for: kind, hasConflicts: false)
    }
    return actions.filter { $0.isVisibleWithConflicts || !hasConflicts }
}
/// IntelliJ GitSmartOperationDialog equivalent. The list is deliberately
/// path-based because Git's overwrite detector is the authoritative source;
/// when a richer local Change model is unavailable, no affected path is hidden.
struct RebasedSmartOperationDialog: View {
    let request: SmartOperationRequest
    let onSmart: () -> Void
    let onForce: () -> Void
    let onCancel: () -> Void

    private var saveMethod: String {
        request.localChangesSavePolicy.title
    }

    private var affectedPaths: [String] {
        var seen = Set<String>()
        return request.paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Local changes would be overwritten")
                    .font(.title3.weight(.semibold))
            }
            Text("\(request.operationTitle) cannot continue because these local changes overlap the target operation.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Smart \(request.operationTitle) temporarily saves local changes as \(saveMethod), performs the operation, then restores them.",
                systemImage: saveMethod == "Shelf" ? "tray.and.arrow.down" : "archivebox"
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            if affectedPaths.isEmpty {
                ContentUnavailableView(
                    "Git did not return affected paths",
                    systemImage: "doc.questionmark",
                    description: Text("Review the operation error before choosing how to continue.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Affected local changes (\(affectedPaths.count))")
                        .font(.headline)
                    List(affectedPaths, id: \.self) { path in
                        Label(path, systemImage: "doc.text")
                            .lineLimit(1)
                            .help(path)
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 160)
                }
            }

            HStack(spacing: 10) {
                if request.onForce != nil, let forceButtonTitle = request.forceButtonTitle {
                    Button(forceButtonTitle, role: .destructive, action: onForce)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(request.smartButtonTitle, action: onSmart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
    }
}
