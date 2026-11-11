import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

/// The real Vcs Log frame has three independent pieces of state:
///
///   graph selection -> commit metadata/details
///   graph selection -> async Changes browser
///   Changes selection -> diff editor tab
///
/// Keeping those pieces in one `CommitDetailView` made a stale detail load
/// able to replace or hide the Changes browser. This wrapper mirrors
/// `MainFrame`: metadata is one splitter component, the Changes browser is
/// another with its own selected path, and the diff is an editor tab owned by
/// `LogSelectionState` so it never shrinks into this narrow inspector.
struct LogCommitInspectorView: View {
    let repo: Repository?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let remotesForCommit: (CommitInfo) -> [RemoteInfo]
    let commits: [CommitInfo]
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onRevertRequested: (CommitInfo) -> Void
    let onCherryPickRequested: (CommitInfo) -> Void
    let onDropSelectedChanges: (CommitInfo, [String]) -> Void
    let onExtractSelectedChanges: (CommitInfo, [String]) -> Void
    let onShowFileHistory: (String) -> Void
    let onShowFileHistoryForRevision: (CommitInfo, String) -> Void
    let onOpenRepositoryVersion: (CommitInfo, String) -> Void
    let onBrowseHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onCopyHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onRestoreRepositoryVersion: ([LogChangeRecord]) -> Void
    let onEditSource: (String) -> Void
    let onApplySelectedChanges: ([LogChangeRecord], Bool) -> Void
    let onCreatePatch: (CommitInfo) -> Void
    let onCreatePatchSelection: ([LogChangeRecord]) -> Void
    let onCopyPatchSelection: ([LogChangeRecord]) -> Void
    let onCreateBranch: (CommitInfo) -> Void
    let showsMetadata: Bool
    /// 与 IntelliJ 的 `Show Diff Preview` 对应：选中文件时直接打开 diff tab。
    let showsDiffPreview: Bool
    let activeDiffRecordID: String?
    let onOpenFileDiff: (LogChangeRecord, LogDiffSource, [LogChangeRecord]) -> Void
    @Binding var showsChangesFromParents: Bool
    @Binding var showsOnlyAffectedChanges: Bool
    let affectedPathSelections: [LogPathFilterSelection]
    /// Dedicated File History context for the VcsHistory.ShowAllAffected
    /// entry; nil keeps the browser free of the history-only action.
    var affectedHistoryPath: String? = nil

    var body: some View {
        Group {
            if showsMetadata {
                // MainFrame's details splitter defaults to 0.7: the Changes
                // browser is the first component. A fixed 280pt ceiling only
                // matches that ratio at one window height.
                LogDetailsProportionSplit {
                    LogChangesBrowserView(
                        repo: repo,
                        repositoryForCommit: repositoryForCommit,
                        remotesForCommit: remotesForCommit,
                        commits: commits,
                        showsDiffPreview: showsDiffPreview,
                        activeDiffRecordID: activeDiffRecordID,
                        onOpenFileDiff: onOpenFileDiff,
                        showsChangesFromParents: $showsChangesFromParents,
                        showsOnlyAffectedChanges: $showsOnlyAffectedChanges,
                        affectedPathSelections: affectedPathSelections,
                        onDropSelectedChanges: onDropSelectedChanges,
                        onExtractSelectedChanges: onExtractSelectedChanges,
                        onShowFileHistory: onShowFileHistory,
                        onShowFileHistoryForRevision: onShowFileHistoryForRevision,
                        onOpenRepositoryVersion: onOpenRepositoryVersion,
                        onBrowseHostedFileRevision: onBrowseHostedFileRevision,
                        onCopyHostedFileRevision: onCopyHostedFileRevision,
                        onRestoreRepositoryVersion: onRestoreRepositoryVersion,
                        onEditSource: onEditSource,
                        onApplySelectedChanges: onApplySelectedChanges,
                        onCreatePatch: onCreatePatch,
                        onCreatePatchSelection: onCreatePatchSelection,
                        onCopyPatchSelection: onCopyPatchSelection,
                        affectedHistoryPath: affectedHistoryPath
                    )
                } bottom: {
                    Group {
                        if commits.count == 1 {
                            CommitDetailsMetadataView(
                                commit: commits[0],
                                repositoryForCommit: repositoryForCommit,
                                remotes: remotesForCommit(commits[0]),
                                onReverted: onReverted,
                                onCherryPicked: onCherryPicked,
                                onRevertRequested: onRevertRequested,
                                onCherryPickRequested: onCherryPickRequested,
                                onCreateBranch: onCreateBranch
                            )
                        } else if !commits.isEmpty {
                            LogMultiMetadataView(
                                commits: commits,
                                onCreateBranch: onCreateBranch
                            )
                        } else {
                            Text("Commit Details")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else {
                LogChangesBrowserView(
                    repo: repo,
                    repositoryForCommit: repositoryForCommit,
                    remotesForCommit: remotesForCommit,
                    commits: commits,
                    showsDiffPreview: showsDiffPreview,
                    activeDiffRecordID: activeDiffRecordID,
                    onOpenFileDiff: onOpenFileDiff,
                    showsChangesFromParents: $showsChangesFromParents,
                    showsOnlyAffectedChanges: $showsOnlyAffectedChanges,
                    affectedPathSelections: affectedPathSelections,
                    onDropSelectedChanges: onDropSelectedChanges,
                    onExtractSelectedChanges: onExtractSelectedChanges,
                    onShowFileHistory: onShowFileHistory,
                    onShowFileHistoryForRevision: onShowFileHistoryForRevision,
                    onOpenRepositoryVersion: onOpenRepositoryVersion,
                    onBrowseHostedFileRevision: onBrowseHostedFileRevision,
                    onCopyHostedFileRevision: onCopyHostedFileRevision,
                    onRestoreRepositoryVersion: onRestoreRepositoryVersion,
                    onEditSource: onEditSource,
                    onApplySelectedChanges: onApplySelectedChanges,
                    onCreatePatch: onCreatePatch,
                    onCreatePatchSelection: onCreatePatchSelection,
                    onCopyPatchSelection: onCopyPatchSelection,
                    affectedHistoryPath: affectedHistoryPath
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// Metadata-only adapter for the existing action-rich commit inspector.
/// `CommitDetailView` intentionally does not load changed files in this mode;
/// the sibling `LogChangesBrowserView` owns that model, matching rebased's
/// `CommitDetailsListPanel` + `VcsLogChangesBrowser` split.
struct CommitDetailsMetadataView: View {
    let commit: CommitInfo?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let remotes: [RemoteInfo]
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onRevertRequested: (CommitInfo) -> Void
    let onCherryPickRequested: (CommitInfo) -> Void
    let onCreateBranch: (CommitInfo) -> Void

    var selectedRepository: Repository? {
        guard let commit else { return nil }
        return repositoryForCommit(commit)
    }

    var body: some View {
        CommitDetailView(
            repo: selectedRepository,
            commit: commit,
            remotes: remotes,
            onReverted: onReverted,
            onCherryPicked: onCherryPicked,
            onCreateBranch: onCreateBranch,
            onRevertRequested: onRevertRequested,
            onCherryPickRequested: onCherryPickRequested,
            showsMetadata: true,
            showsDiffPreview: false,
            showsChanges: false,
            compactMetadata: true
        )
    }
}


/// IntelliJ's details panel is a list panel, not a single-commit inspector:
/// Cmd/Shift selection in the graph produces one details card per selected
/// commit while the changes browser remains usable below it. The old Arbor
/// view highlighted several rows but silently kept showing only the active
/// row, which made multi-selection look broken. Keep the common changes and
/// diff surface lightweight, and load each selected commit's tree off the
/// main actor.
var selectedLogCommits: [CommitInfo] {
    let entries = logList.viewMode == .command ? logRuntime.commandEntries : logList.entries
    let selected = entries.filter { logSelectionState.selectedIDs.contains(logCommitIdentity($0)) }
    if selected.count > 1 { return selected }
    if let selectedCommit { return [selectedCommit] }
    return []
}

}


/// Top-pane fraction for `vcs.log.details.splitter.proportion`.
/// Rebased 1.1.13 constructs that splitter with a default of 0.7 and puts the
/// Changes browser in the first component.
func logDetailsSplitterPosition(
    totalHeight: CGFloat,
    proportion: CGFloat,
    minimumTop: CGFloat,
    minimumBottom: CGFloat,
    dividerThickness: CGFloat
) -> CGFloat {
    let maxTop = max(0, totalHeight - dividerThickness - minimumBottom)
    let minTop = min(minimumTop, maxTop)
    return min(max(totalHeight * proportion, minTop), maxTop)
}

private enum LogDetailsSplitterMetrics {
    static let storageKey = "arbor.log.details.splitter.proportion.v1"
    static let defaultProportion = 0.7
    static let minimumTop: CGFloat = 180
    static let minimumBottom: CGFloat = 120
}

private struct LogDetailsProportionSplit<Top: View, Bottom: View>: View {
    private let top: Top
    private let bottom: Bottom

    init(
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        ProportionSplit(
            storageKey: LogDetailsSplitterMetrics.storageKey,
            defaultProportion: LogDetailsSplitterMetrics.defaultProportion,
            minimumTop: LogDetailsSplitterMetrics.minimumTop,
            minimumBottom: LogDetailsSplitterMetrics.minimumBottom,
            top: top,
            bottom: bottom
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("log-details-splitter")
    }

    private struct ProportionSplit: NSViewRepresentable {
        let storageKey: String
        let defaultProportion: Double
        let minimumTop: CGFloat
        let minimumBottom: CGFloat
        let top: Top
        let bottom: Bottom

        final class SplitView: NSSplitView {
            var onLayout: (() -> Void)?
            var onResizeEnded: (() -> Void)?

            override func layout() {
                super.layout()
                onLayout?()
            }

            override func mouseDown(with event: NSEvent) {
                super.mouseDown(with: event)
                onResizeEnded?()
            }
        }

        final class Coordinator: NSObject, NSSplitViewDelegate {
            var parent: ProportionSplit
            weak var splitView: SplitView?
            weak var topHost: NSHostingView<Top>?
            weak var bottomHost: NSHostingView<Bottom>?
            var lastAppliedHeight: CGFloat = -1
            var lastAppliedProportion: Double = -1
            var rootUpdateScheduled = false

            init(parent: ProportionSplit) {
                self.parent = parent
            }

            func storedProportion() -> Double {
                let defaults = UserDefaults.standard
                guard defaults.object(forKey: parent.storageKey) != nil else {
                    return parent.defaultProportion
                }
                return defaults.double(forKey: parent.storageKey)
            }

            private var isApplying = false

            func applyStoredPositionIfNeeded() {
                guard !isApplying, let splitView, splitView.subviews.count == 2 else { return }
                let height = splitView.bounds.height
                let proportion = storedProportion()
                guard height > 1 else { return }
                guard abs(height - lastAppliedHeight) > 0.5
                        || abs(proportion - lastAppliedProportion) > 0.000_1 else { return }
                let position = logDetailsSplitterPosition(
                    totalHeight: height,
                    proportion: CGFloat(proportion),
                    minimumTop: parent.minimumTop,
                    minimumBottom: parent.minimumBottom,
                    dividerThickness: splitView.dividerThickness
                )
                isApplying = true
                splitView.setPosition(position, ofDividerAt: 0)
                isApplying = false
                lastAppliedHeight = height
                lastAppliedProportion = proportion
            }

            func commitCurrentPosition() {
                guard let splitView, splitView.subviews.count == 2 else { return }
                let height = splitView.bounds.height
                guard height > 1 else { return }
                let proportion = Double(splitView.subviews[0].frame.height / height)
                UserDefaults.standard.set(proportion, forKey: parent.storageKey)
                lastAppliedHeight = height
                lastAppliedProportion = proportion
            }

            func splitView(
                _ splitView: NSSplitView,
                constrainMinCoordinate proposedMinimumPosition: CGFloat,
                ofSubviewAt dividerIndex: Int
            ) -> CGFloat {
                let maxTop = max(
                    0,
                    splitView.bounds.height - parent.minimumBottom - splitView.dividerThickness
                )
                return min(parent.minimumTop, maxTop)
            }

            func splitView(
                _ splitView: NSSplitView,
                constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                ofSubviewAt dividerIndex: Int
            ) -> CGFloat {
                max(
                    0,
                    splitView.bounds.height - parent.minimumBottom - splitView.dividerThickness
                )
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        func makeNSView(context: Context) -> SplitView {
            let splitView = SplitView()
            splitView.isVertical = false
            splitView.dividerStyle = .thin
            splitView.delegate = context.coordinator
            let topHost = NSHostingView(rootView: top)
            let bottomHost = NSHostingView(rootView: bottom)
            topHost.sizingOptions = []
            bottomHost.sizingOptions = []
            for host in [topHost, bottomHost] as [NSView] {
                host.translatesAutoresizingMaskIntoConstraints = false
                host.setContentHuggingPriority(.defaultLow, for: .vertical)
                host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            }
            splitView.addArrangedSubview(topHost)
            splitView.addArrangedSubview(bottomHost)
            context.coordinator.splitView = splitView
            context.coordinator.topHost = topHost
            context.coordinator.bottomHost = bottomHost
            splitView.onLayout = { [weak coordinator = context.coordinator] in
                coordinator?.applyStoredPositionIfNeeded()
            }
            splitView.onResizeEnded = { [weak coordinator = context.coordinator] in
                coordinator?.commitCurrentPosition()
            }
            return splitView
        }

        func updateNSView(_ splitView: SplitView, context: Context) {
            let coordinator = context.coordinator
            coordinator.parent = self
            guard !coordinator.rootUpdateScheduled else { return }
            coordinator.rootUpdateScheduled = true
            DispatchQueue.main.async { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.rootUpdateScheduled = false
                coordinator.topHost?.rootView = coordinator.parent.top
                coordinator.bottomHost?.rootView = coordinator.parent.bottom
                coordinator.applyStoredPositionIfNeeded()
            }
        }
    }
}
