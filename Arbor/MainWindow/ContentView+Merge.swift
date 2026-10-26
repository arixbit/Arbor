import SwiftUI
import AppKit

extension ContentView {

    var mergeDeleteOnMergeOption: GitDeleteOnMergeOption {
        GitDeleteOnMergeOption(rawValue: mergeDeleteOnMergeRaw)
            ?? GitDeleteOnMergeOption.defaultOption
    }

    func openFirstConflictFromAction() {
        guard let conflictedPath = firstConflictedPath(in: repositoryStatus.entries) else { return }
        openConflictFromStage(conflictedPath)
    }

    func openConflictFromStage(_ path: String) {
        // The resolver is a sheet over the current workspace. In Log mode the
        // right editor must remain the Log graph, so pass the initial file via
        // a dedicated dialog context instead of the global editor selection.
        operationRecovery.initialPath = path
        if projectWorkspace.toolWindowMode != .log { fileWorkspace.selection = path }
        fileWorkspace.fileSelection = nil
        fileWorkspace.selectionModePath = nil
        fileWorkspace.previewPath = nil
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewVisible = false
        fileWorkspace.previewThreeVersions = false
        operationRecovery.showConflictResolver = true
    }

    /// CONFLICT-001：merge/rebase/cherry-pick/revert 进入同一冲突工作台。
    private var mergeRevisionsMode: MergeRevisionsDialogView.Mode {
        if stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress {
            return .stashRestore
        }
        if shelfWorkspace.conflictInProgress {
            if shelfWorkspace.conflictIsDirectPatch {
                return .applyPatch
            }
            return .shelveRestore(isPop: shelfWorkspace.conflictIsPop)
        }
        switch operationRecovery.operation?.kind {
        case .rebase: return .rebase
        case .cherryPick: return .cherryPick
        case .revert: return .revert
        default: return .merge
        }
    }

    private var mergeRevisionsAbortAction: (() -> Void)? {
        if shelfWorkspace.conflictInProgress {
            return { abortShelveConflict() }
        }
        if stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress {
            return nil
        }
        return {
            doOperationAbort()
            operationRecovery.showConflictResolver = false
        }
    }

    /// IntelliJ keeps the conflict resolver in a non-modal tool window: the
    /// user can hide it, inspect the rest of the project, and reopen it from
    /// the operation bar or conflict notification without changing the
    /// in-progress Git state. Keep
    /// the resolver itself as the single source of truth and only change its
    /// presentation here.
    @ViewBuilder
    var conflictResolverOverlays: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                if operationRecovery.showConflictResolver {
                    singleRootConflictResolverPanel
                        .frame(width: min(1000, geometry.size.width - 28),
                               height: min(680, geometry.size.height - 28))
                        .padding(14)
                }
                if operationRecovery.showMultiRootConflictResolver {
                    multiRootConflictResolverPanel
                        .frame(width: min(1060, geometry.size.width - 28),
                               height: min(700, geometry.size.height - 28))
                        .padding(14)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var singleRootConflictResolverPanel: some View {
        if let repo = shelfWorkspace.pendingConflictRepository ?? self.repo {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Resolve Conflicts")
                        .font(.headline)
                    Text(LocalizedStringKey(mergeRevisionsMode.title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") {
                        operationRecovery.showConflictResolver = false
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
                MergeRevisionsDialogView(
                    repo: repo,
                    entries: $repositoryStatus.entries,
                    initialPath: operationRecovery.initialPath ?? fileWorkspace.selection,
                    mode: mergeRevisionsMode,
                    directPatchText: shelfWorkspace.conflictIsDirectPatch ? shelfWorkspace.pendingConflictPatch : nil,
                    directPatchRestoreName: shelfWorkspace.conflictIsDirectPatch ? shelfWorkspace.pendingConflictName : nil,
                    onChanged: {
                        if shelfWorkspace.conflictInProgress {
                            refreshShelveConflictStatus()
                        } else {
                            refreshAll()
                        }
                    },
                    onComplete: {
                        if shelfWorkspace.conflictInProgress {
                            finishShelveConflict()
                        } else {
                            doOperationContinue()
                            operationRecovery.showConflictResolver = false
                            operationRecovery.initialPath = nil
                        }
                    },
                    onAbort: mergeRevisionsAbortAction,
                    onSkip: nil,
                    compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var multiRootConflictResolverPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Git Roots Conflicts")
                    .font(.headline)
                Spacer()
                Button("Close", action: closeMultiRootResolver)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            MultiRootConflictResolverView(
                roots: operationRecovery.multiRootResolverRoots,
                activeRootPath: operationRecovery.multiRootResolverActiveRootPath,
                activeRepo: operationRecovery.multiRootResolverActiveRepo,
                entries: $operationRecovery.multiRootResolverActiveEntries,
                initialPath: operationRecovery.multiRootResolverActiveInitialPath,
                activeKind: operationRecovery.multiRootResolverActiveKind,
                isWorking: operationRecovery.multiRootResolverWorking,
                error: operationRecovery.multiRootResolverError,
                onSelectRoot: selectMultiRootResolverRoot,
                onChanged: refreshMultiRootResolverActiveRoot,
                onComplete: completeMultiRootResolverRoot,
                onSkip: skipMultiRootResolverRoot,
                onAbort: abortMultiRootResolverRoot,
                onClose: closeMultiRootResolver,
                compact: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .zIndex(21)
    }

    func openMergeDialog(_ branch: String?) {
        guard operationRecovery.operation?.kind == nil,
              isArborVCSActionVisible(.merge, in: vcsActionContext),
              isArborVCSActionEnabled(.merge, in: vcsActionContext) else { return }
        loadMergeDialogSettings(for: projectWorkspace.path)
        if let branch { mergeWorkspace.branch = branch }
        mergeWorkspace.dialogGeneration &+= 1
        let generation = mergeWorkspace.dialogGeneration
        mergeWorkspace.mergedBranches = []
        mergeWorkspace.showActionDialog = true
        guard let repo else { return }
        Task.detached(priority: .userInitiated) {
            let mergedBranches = (try? repo.branchListMerged().map(\.name)) ?? []
            await MainActor.run {
                guard generation == self.mergeWorkspace.dialogGeneration else { return }
                self.mergeWorkspace.mergedBranches = Set(mergedBranches)
            }
        }
    }

    func loadMergeDialogSettings(for projectPath: String?) {
        let settings = GitMergeDialogSettingsStore.load(for: projectPath)
        mergeWorkspace.branch = settings.branch
        mergeWorkspace.strategyRaw = settings.strategyRaw
        mergeWorkspace.useCustomCommitMessage = settings.useCustomCommitMessage
        mergeWorkspace.noCommit = settings.noCommit
        mergeWorkspace.noVerify = settings.noVerify
        mergeWorkspace.allowUnrelatedHistories = settings.allowUnrelatedHistories
        if !mergeWorkspace.useCustomCommitMessage {
            mergeWorkspace.commitMessage = ""
        }
    }

    func saveMergeDialogSettings() {
        GitMergeDialogSettingsStore.save(
            GitMergeDialogSettings(
                branch: mergeWorkspace.branch,
                strategyRaw: mergeWorkspace.strategyRaw,
                useCustomCommitMessage: mergeWorkspace.useCustomCommitMessage,
                noCommit: mergeWorkspace.noCommit,
                noVerify: mergeWorkspace.noVerify,
                allowUnrelatedHistories: mergeWorkspace.allowUnrelatedHistories
            ),
            for: projectWorkspace.path
        )
    }
}
