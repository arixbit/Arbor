import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct GitMergeRebaseWidgetItem: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let operation: OperationKind
    let isCurrent: Bool

    var id: String { canonicalExternalLogPath(rootPath) }

    var operationTitle: String {
        switch operation {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        }
    }

    var continueTitle: String {
        switch operation {
        case .merge: return "Commit Merge"
        case .rebase: return "Continue Rebase"
        case .cherryPick: return "Continue Cherry-pick"
        case .revert: return "Continue Revert"
        }
    }

    var widgetTitle: String {
        switch operation {
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase paused"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        }
    }

    var icon: String {
        switch operation {
        case .merge: return "arrow.triangle.merge"
        case .rebase: return "arrow.triangle.branch"
        case .cherryPick: return "doc.on.clipboard"
        case .revert: return "arrow.uturn.backward"
        }
    }
}

/// Build the project-toolbar operation list from the live selected-root state
/// plus the last discovered state for every other root. A live nil state also
/// removes a stale snapshot entry for the selected root.
func gitMergeRebaseWidgetItems(
    currentRootPath: String?,
    currentOperation: OperationKind?,
    roots: [GitRootInfo]
) -> [GitMergeRebaseWidgetItem] {
    let currentPath = currentRootPath.map(canonicalExternalLogPath)
    var itemsByPath: [String: GitMergeRebaseWidgetItem] = [:]

    for root in roots {
        guard let operation = root.operation else { continue }
        let rootPath = canonicalExternalLogPath(root.path)
        itemsByPath[rootPath] = GitMergeRebaseWidgetItem(
            rootPath: rootPath,
            displayName: root.displayName,
            relativePath: root.relativePath,
            operation: operation,
            isCurrent: rootPath == currentPath
        )
    }

    if let currentPath {
        if let currentOperation {
            let snapshot = itemsByPath[currentPath]
            itemsByPath[currentPath] = GitMergeRebaseWidgetItem(
                rootPath: currentPath,
                displayName: snapshot?.displayName
                    ?? URL(fileURLWithPath: currentPath).lastPathComponent,
                relativePath: snapshot?.relativePath ?? ".",
                operation: currentOperation,
                isCurrent: true
            )
        } else {
            itemsByPath.removeValue(forKey: currentPath)
        }
    }

    return itemsByPath.values.sorted { lhs, rhs in
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        if lhs.relativePath != rhs.relativePath {
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        return lhs.rootPath < rhs.rootPath
    }
}

/// IntelliJ's `main.toolbar.git.MergeRebase` action group, adapted to the
/// project toolbar. Direct actions are offered only for the live selected
/// root; another active root opens its own recovery context first.
struct GitMergeRebaseWidget: View {
    let items: [GitMergeRebaseWidgetItem]
    let currentOperationState: OperationState?
    let resolvedConflictPaths: [String]
    let onRevertResolved: (String) -> Void
    let onOperationAction: (
        ArborVCSActionRequest.OperationRecoveryAction,
        String
    ) -> Void

    var body: some View {
        if let primaryItem = items.first {
            Menu {
                ForEach(items) { item in
                    Section {
                        if item.isCurrent,
                           let state = currentOperationState,
                           state.kind == item.operation
                        {
                            if !state.conflictedFiles.isEmpty {
                                Button("Resolve Conflicts") {
                                    onOperationAction(.openRecovery, item.rootPath)
                                }
                            }
                            if !resolvedConflictPaths.isEmpty {
                                Menu("Revert Resolved") {
                                    ForEach(resolvedConflictPaths, id: \.self) { path in
                                        Button("Revert \(path)") {
                                            onRevertResolved(path)
                                        }
                                    }
                                }
                            }
                            Button(item.continueTitle) {
                                onOperationAction(.continueOperation, item.rootPath)
                            }
                            .disabled(
                                item.operation == .merge
                                    && !state.conflictedFiles.isEmpty
                            )
                            if item.operation == .rebase {
                                Button("Skip Rebase Step") {
                                    onOperationAction(.skip, item.rootPath)
                                }
                            }
                            Button("Abort \(item.operationTitle)", role: .destructive) {
                                onOperationAction(.abort, item.rootPath)
                            }
                        }
                        Button("Open Recovery") {
                            onOperationAction(.openRecovery, item.rootPath)
                        }
                    } header: {
                        Text(item.isCurrent ? item.widgetTitle : "\(item.widgetTitle) · \(item.displayName)")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: primaryItem.icon)
                    Text(primaryItem.widgetTitle)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
            .menuStyle(.borderlessButton)
            .help(operationHelpText(for: primaryItem))
        }
    }

    func operationHelpText(for item: GitMergeRebaseWidgetItem) -> String {
        if items.count == 1 { return item.widgetTitle }
        return "\(item.widgetTitle) in \(item.displayName) and other Git roots"
    }
}


/// OPS-001 Operation Recovery Bar：订阅引擎的 operation_state()，
/// 按操作类别展示 continue/skip/abort；危险状态下普通操作按钮已禁用。
func rebaseEditPauseAllowsAmend(_ state: OperationState?) -> Bool {
    state?.kind == .rebase
        && state?.conflictedFiles.isEmpty == true
}
