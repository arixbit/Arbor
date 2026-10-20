import SwiftUI
import AppKit

extension ContentView {

    /// Include repository identity so a project restored before its
    /// repository finishes loading starts the monitor when the repo arrives,
    /// and a linked worktree switch replaces the watched Git directory.
    var repositoryIndexMonitorID: String {
        "\(projectWorkspace.path ?? "")|\(repo?.gitDir() ?? "closed")"
    }

    var autoFetchRootPaths: [String] {
        mergedAutoFetchRootPaths(
            primary: repo?.workdir(),
            discovered: multiRootWorkspace.roots.map(\.path)
        )
    }

    var autoFetchMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))|\(incomingCheckStrategy.rawValue)|tags-\(fetchTagsMode)|run-\(gitSettings.autoFetchRunGeneration)"
    }

    var shelfLifecycleMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))"
    }

    var autoFetchNotificationIDPrefix: String {
        let identity = projectWorkspace.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "no-project"
        return "git.fetch.\(identity)"
    }

    private var multiRootMergePresentedView: some View {
        mainView
            .modifier(
                MultiRootMergePresentationModifier(
                    isPresented: $mergeWorkspace.showMultiRootDialog,
                    selectedRootPaths: $mergeWorkspace.multiRootSelectedRootPaths,
                    strategy: Binding(
                        get: { MergeStrategyChoice(rawValue: mergeWorkspace.strategyRaw) ?? .automatic },
                        set: { mergeWorkspace.strategyRaw = $0.rawValue }
                    ),
                    commitMessage: $mergeWorkspace.commitMessage,
                    useCustomCommitMessage: $mergeWorkspace.useCustomCommitMessage,
                    noCommit: $mergeWorkspace.noCommit,
                    noVerify: $mergeWorkspace.noVerify,
                    allowUnrelatedHistories: $mergeWorkspace.allowUnrelatedHistories,
                    rollbackContext: $mergeWorkspace.multiRootRollbackContext,
                    branchName: mergeWorkspace.multiRootBranchName,
                    snapshots: multiRootWorkspace.branchSnapshots,
                    mergedBranchesByRoot: mergeWorkspace.multiRootMergedBranchesByRoot,
                    onMerge: startMultiRootMergeFromDialog,
                    onCancel: dismissMultiRootMergeDialog,
                    onRollback: { targets in rollbackMultiRootMerge(targets) },
                    onKeep: keepMultiRootMergePartial,
                    onDone: dismissMultiRootMergeRollback
                )
            )
            .onReceive(
                NotificationCenter.default.publisher(for: .arborDeleteMergedBranch),
                perform: handleMergeDeleteNotification
            )
    }

    private var repositoryIndexMonitoredView: some View {
        multiRootMergePresentedView
        .background {
            RepositoryIndexRevisionMonitor(
                repo: repo,
                repositoryID: "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))",
                rootPaths: autoFetchRootPaths,
                onChanged: handleRepositoryChange
            )
        }
    }

    var workspaceLifecycleView: some View {
        repositoryIndexMonitoredView
        .background {
            let expectedGitDir = repo?.gitDir()
            let expectedMonitorID = autoFetchMonitorID
            GitAutoFetchMonitor(
                rootPaths: autoFetchRootPaths,
                repositoryID: autoFetchMonitorID,
                broker: credentialAuth.broker,
                strategy: feedbackCenter.isRunning ? .none : incomingCheckStrategy,
                tagMode: fetchTagsMode,
                onUpdated: { updatedRefs in
                    guard !updatedRefs.isEmpty,
                          self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    gitSettings.autoFetchIncomingFingerprint = nil
                    gitSettings.autoFetchFailureFingerprint = nil
                    DiagnosticsLogger.shared.record(
                        operation: "auto-fetch",
                        repositoryPath: projectWorkspace.path,
                        code: "updated-\(updatedRefs.count)-refs"
                    )
                    loadRepoData(includeComparisons: false)
                    loadMultiRoots()
                    refreshAll(showFeedback: false)
                },
                onUnfetched: { snapshot in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    gitSettings.autoFetchIncomingBranches = applyingAutoFetchIncomingSnapshot(
                        snapshot,
                        to: gitSettings.autoFetchIncomingBranches
                    )
                    guard !gitSettings.autoFetchIncomingBranches.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
                        gitSettings.autoFetchIncomingFingerprint = nil
                        return
                    }
                    let displayValues = groupedAutoFetchIncomingBranches(
                        Array(gitSettings.autoFetchIncomingBranches)
                    ).map(\.displayValue)
                    let fingerprint = autoFetchNotificationFingerprint(displayValues)
                    guard fingerprint != gitSettings.autoFetchIncomingFingerprint else { return }
                    gitSettings.autoFetchIncomingFingerprint = fingerprint
                    feedbackCenter.warning(
                        "Incoming changes available",
                        detail: displayValues.joined(separator: "\n"),
                        nextStep: "Run Fetch to update the local remote-tracking refs.",
                        additionalActions: [
                            self.autoFetchRecoveryFeedbackAction(
                                .fetchAll,
                                rootPaths: self.autoFetchRootPaths
                            )
                        ],
                        notificationID: "\(autoFetchNotificationIDPrefix).incoming",
                        localized: false
                    )
                },
                onFailure: { failures in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    guard !failures.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
                        gitSettings.autoFetchFailureFingerprint = nil
                        return
                    }
                    let fingerprint = autoFetchNotificationFingerprint(failures)
                    guard fingerprint != gitSettings.autoFetchFailureFingerprint else { return }
                    gitSettings.autoFetchFailureFingerprint = fingerprint
                    let retryAction = self.autoFetchRecoveryFeedbackAction(
                        .retryCheck,
                        rootPaths: self.autoFetchRootPaths
                    )
                    let fetchAction = self.autoFetchRecoveryFeedbackAction(
                        .fetchAll,
                        rootPaths: self.autoFetchRootPaths
                    )
                    feedbackCenter.warning(
                        incomingCheckStrategy == .fetch
                            ? "Auto-fetch failed"
                            : "Incoming changes check failed",
                        detail: failures.joined(separator: "\n"),
                        nextStep: "Check the remote and authentication settings, then retry.",
                        additionalActions: incomingCheckStrategy == .fetch
                            ? [retryAction]
                            : [retryAction, fetchAction],
                        notificationID: "\(autoFetchNotificationIDPrefix).error",
                        localized: false
                    )
                }
            )
        }
        .background {
            GitShelfLifecycleMonitor(
                rootPaths: autoFetchRootPaths,
                repositoryID: shelfLifecycleMonitorID
            )
        }
        .onChange(of: autoFetchMonitorID) { _, _ in
            gitSettings.autoFetchFailureFingerprint = nil
            gitSettings.autoFetchIncomingFingerprint = nil
            gitSettings.autoFetchIncomingBranches = []
        }
        .onChange(of: incomingOutgoingInfoEnabled) { _, enabled in
            guard !enabled else { return }
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
            gitSettings.autoFetchFailureFingerprint = nil
            gitSettings.autoFetchIncomingFingerprint = nil
            gitSettings.autoFetchIncomingBranches = []
        }
        .onAppear {
            setExternalConversionEnabled(enabled: gitExternalConversionEnabled)
            applyExternalConversionSetting()
        }
        .onChange(of: gitExternalConversionEnabled) { _, enabled in
            setExternalConversionEnabled(enabled: enabled)
            applyExternalConversionSetting()
            refreshAll(showFeedback: false)
        }
        .focusedValue(\.arborRepositoryIsShallow, projectWorkspace.repository == nil ? nil : repositoryStatus.isShallowRepository)
        .focusedValue(\.arborRepositoryAvailable, repo != nil)
        .focusedValue(\.arborVCSActionContext, vcsActionContext)
        .focusedValue(
            \.arborVCSOperationContext,
            operationRecovery.operation.flatMap { state in
                repo?.workdir().map {
                    ArborVCSOperationContext(
                        rootPath: $0,
                        kind: state.kind,
                        hasConflicts: !state.conflictedFiles.isEmpty
                    )
                }
            }
        )
        .background {
            if externalLogWindow {
                ExternalLogWindowLifecycleView(onClosed: disposeExternalLogSession)
            }
        }
        .onDisappear {
            vcsQuickActionsPanel.close()
            if externalLogWindow {
                disposeExternalLogSession()
            }
        }
    }
}
