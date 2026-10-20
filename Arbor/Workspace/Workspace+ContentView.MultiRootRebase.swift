import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Prepare one independent todo list per root before starting a batch rebase.
/// The preparation step is intentionally separate from execution so a user
/// can inspect every root's range and fix an invalid branch/ref before any
/// repository is rewritten.
func prepareMultiRootRebaseEditor() {
    guard !multiRootWorkspace.roots.isEmpty else { return }
    let onto = rebaseWorkspace.onto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseWorkspace.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootMode = rebaseWorkspace.root
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: rootMode) else { return }

    let roots = multiRootWorkspace.roots
    let preserveMerges = rebaseWorkspace.preserveMerges
    beginFeedbackOperation("Prepare multi-root rebase")
    Task.detached(priority: .userInitiated) {
        var drafts: [MultiRootRebaseTodoDraft] = []
        for root in roots {
            do {
                let rootRepo = try openRepository(path: root.path)
                let todo = try rootRepo.rebaseTodoForBranchWithOptions(
                    onto: onto,
                    // Keep the initial visible rows in native commit order;
                    // later edits carry their commit identities in the
                    // structured multi-root spec.
                    autoSquash: false,
                    preserveMerges: preserveMerges,
                    root: rootMode,
                    branch: branch
                )
                drafts.append(
                    MultiRootRebaseTodoDraft(
                        rootPath: root.path,
                        displayName: root.displayName,
                        items: todo.items,
                        rawTodo: nil,
                        loadError: nil
                    )
                )
            } catch {
                drafts.append(
                    MultiRootRebaseTodoDraft(
                        rootPath: root.path,
                        displayName: root.displayName,
                        items: [],
                        rawTodo: nil,
                        loadError: errorMessage(error)
                    )
                )
            }
        }
        let preparedDrafts = drafts
        await MainActor.run {
            self.rebaseWorkspace.multiRootDrafts = preparedDrafts
            self.rebaseWorkspace.showMultiRootEditor = true
            let failures = preparedDrafts.filter { $0.loadError != nil }
            if failures.isEmpty {
                let count = preparedDrafts.reduce(0) { $0 + $1.items.count }
                self.feedbackCenter.success(
                    "Multi-root rebase prepared",
                    detail: String(count) + " commits across " + String(preparedDrafts.count) + " repositories"
                )
            } else {
                self.feedbackCenter.error(
                    "Multi-root rebase range incomplete",
                    detail: failures.map { "\($0.displayName): \($0.loadError ?? "Unknown error")" }.joined(separator: "\n"),
                    nextStep: "Fix the branch or onto revision, then reload the ranges."
                )
            }
        }
    }
}

/// Execute the edited per-root todo lists as one dependency-ordered batch.
/// The Rust engine stops at the first paused/failed root and returns the
/// already completed and skipped roots for the same partial-result model as
/// IntelliJ's GitRebaseSpec/GitRebaseProcess.
func doMultiRootRebase(drafts: [MultiRootRebaseTodoDraft]?) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    guard let projectPath = projectWorkspace.path, !multiRootWorkspace.roots.isEmpty else { return }
    let onto = rebaseWorkspace.onto.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = rebaseWorkspace.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootMode = rebaseWorkspace.root
    guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: rootMode) else { return }

    let draftsByPath = Dictionary(uniqueKeysWithValues: (drafts ?? []).map { ($0.rootPath, $0) })
    if rebaseWorkspace.interactive {
        guard multiRootWorkspace.roots.allSatisfy({
            guard let draft = draftsByPath[$0.path] else { return false }
            return draft.loadError == nil && !draft.items.isEmpty
        }) else {
            feedbackCenter.error(
                "Multi-root rebase is not ready",
                detail: "Every repository must have a loaded, non-empty todo list.",
                nextStep: "Reload the ranges and review each repository before starting."
            )
            return
        }
    }

    let savePolicyRaw = GitLocalChangesSavePolicySettings.choice(for: projectPath).rawValue
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)

    let specs = multiRootWorkspace.roots.compactMap { root -> MultiRootRebaseSpec? in
        let actions: [RebaseAction]
        if rebaseWorkspace.interactive {
            guard let draft = draftsByPath[root.path] else { return nil }
            actions = draft.items.map { item -> RebaseAction in
                switch item.action {
                case .pick:
                    return .pick
                case .drop:
                    return .drop
                case .reword:
                    return .reword(message: item.message ?? item.summary)
                case .squash:
                    if let message = item.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !message.isEmpty {
                        return .squashWithMessage(message: message)
                    }
                    return .squash
                case .fixup:
                    return .fixup
                case .edit:
                    return .edit
                }
            }
        } else {
            actions = []
        }
        return MultiRootRebaseSpec(
            rootPath: root.path,
            branch: branch,
            onto: onto,
            actions: actions,
            orderedCommitIds: rebaseWorkspace.interactive
                && rebaseWorkspace.preserveMerges
                && draftsByPath[root.path]?.rawTodo == nil
                ? (draftsByPath[root.path]?.items.map(\.commitId) ?? [])
                : [],
            rawTodo: draftsByPath[root.path]?.rawTodo,
            preserveMerges: rebaseWorkspace.preserveMerges,
            autoSquash: rebaseWorkspace.autoSquash,
            keepEmpty: rebaseWorkspace.keepEmpty,
            updateRefs: rebaseWorkspace.updateRefs,
            root: rootMode,
            interactive: rebaseWorkspace.interactive,
            savePolicy: savePolicy
        )
    }
    guard specs.count == multiRootWorkspace.roots.count else { return }

    let session = MultiRootRebaseSession(
        projectPath: projectPath,
        roots: specs.map { spec in
            let displayName = multiRootWorkspace.roots.first(where: { $0.path == spec.rootPath })?.displayName
                ?? URL(fileURLWithPath: spec.rootPath).lastPathComponent
            return MultiRootRebaseSessionRoot(
                rootPath: spec.rootPath,
                displayName: displayName,
                branch: spec.branch,
                onto: spec.onto,
                actions: spec.actions.map(PersistedRebaseAction.init),
                orderedCommitIds: spec.orderedCommitIds.isEmpty ? nil : spec.orderedCommitIds,
                rawTodo: spec.rawTodo,
                preserveMerges: spec.preserveMerges,
                autoSquash: spec.autoSquash,
                keepEmpty: spec.keepEmpty,
                updateRefs: spec.updateRefs,
                root: spec.root,
                savePolicyRaw: savePolicyRaw,
                state: .pending,
                initialHead: nil,
                expectedHead: nil,
                initialBranch: nil,
                message: ""
            )
        }
    )
    rebaseWorkspace.multiRootSession = session
    saveMultiRootRebaseSession(session)
    rebaseWorkspace.rangeGeneration += 1
    runPendingMultiRootRebase(session)
}

func runPendingMultiRootRebase(_ session: MultiRootRebaseSession) {
    guard !multiRootWorkspace.running else { return }
    let pendingRoots = session.roots.filter { $0.state == .pending }
    guard !pendingRoots.isEmpty else { return }
    let specs = pendingRoots.map { $0.makeSpec() }
    let sessionID = session.id
    let cancel = GitCancelHandle()
    multiRootWorkspace.running = true
    beginFeedbackOperation(
        "Multi-root Rebase",
        cancelHandle: cancel,
        notificationID: multiRootRebaseNotificationID()
    )
    if session.roots.contains(where: { $0.state != .pending }) {
        feedbackCenter.attachResultRows(
            multiRootRebaseFeedbackResultRows(for: session),
            notificationID: multiRootRebaseNotificationID()
        )
    }
    Task.detached(priority: .userInitiated) {
        var activeRootPath: String?
        for root in pendingRoots {
            if let rootRepo = try? openRepository(path: root.rootPath),
               (try? rootRepo.operationState()) != nil {
                activeRootPath = root.rootPath
                break
            }
        }
        if let activeRootPath {
            if let activeRepo = try? openRepository(path: activeRootPath) {
                Task.detached(priority: .userInitiated) {
                    while !Task.isCancelled {
                        if let pending = try? activeRepo.rebasePendingMessage() {
                            await MainActor.run {
                                guard self.rebaseWorkspace.multiRootSession?.id == sessionID,
                                      !self.rebaseWorkspace.showRawMessageEditor else { return }
                                self.rebaseWorkspace.rawMessageRepository = activeRepo
                                self.rebaseWorkspace.rawMessageText = pending
                                self.rebaseWorkspace.showRawMessageEditor = true
                            }
                        }
                        if (try? activeRepo.operationState()) == nil {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            await MainActor.run {
                guard self.rebaseWorkspace.multiRootSession?.id == sessionID else { return }
                self.multiRootWorkspace.running = false
                self.feedbackCenter.warning(
                    "Multi-root rebase paused",
                    detail: "A Git rebase is already in progress in \(activeRootPath).",
                    additionalActions: [
                        self.multiRootRebaseRecoveryFeedbackAction(
                            .openRecovery,
                            rootPath: activeRootPath,
                            sessionID: sessionID
                        )
                    ],
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.feedbackCenter.attachResultRows(
                    multiRootRebaseFeedbackResultRows(for: session),
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.openMultiRootConflictResolver(preferredRootPath: activeRootPath)
            }
            return
        }
        var protectionCommitIDs: [String: String] = [:]
        for root in pendingRoots {
            guard let rootRepo = try? openRepository(path: root.rootPath),
                  let initialHead = try? rootRepo.revisionCommitId(revision: root.branch),
                  let protectionCommitID = rebaseUndoProtectionCommitBeforeOperation(
                      repo: rootRepo,
                      initialHead: initialHead,
                      onto: root.onto
                  ) else { continue }
            protectionCommitIDs[root.rootPath] = protectionCommitID
        }
        if !protectionCommitIDs.isEmpty {
            let recordedProtectionCommitIDs = protectionCommitIDs
            await MainActor.run {
                guard var current = self.rebaseWorkspace.multiRootSession,
                      current.id == sessionID else { return }
                for index in current.roots.indices {
                    if let protectionCommitID = recordedProtectionCommitIDs[current.roots[index].rootPath] {
                        current.roots[index].protectionCommitID = protectionCommitID
                    }
                }
                self.rebaseWorkspace.multiRootSession = current
                saveMultiRootRebaseSession(current)
            }
        }
        let messageMonitorRepositories = pendingRoots.compactMap {
            try? openRepository(path: $0.rootPath)
        }
        let messageMonitorPaths = Set(pendingRoots.map(\.rootPath))
        let messageMonitor = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                for rootRepo in messageMonitorRepositories {
                    if let pending = try? rootRepo.rebasePendingMessage() {
                        await MainActor.run {
                            guard !self.rebaseWorkspace.showRawMessageEditor else { return }
                            self.rebaseWorkspace.rawMessageRepository = rootRepo
                            self.rebaseWorkspace.rawMessageText = pending
                            self.rebaseWorkspace.showRawMessageEditor = true
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        do {
            let results = try runMultiRootRebaseWithCancel(specs: specs, cancel: cancel)
            messageMonitor.cancel()
            await MainActor.run {
                guard let current = self.rebaseWorkspace.multiRootSession,
                      current.id == sessionID else { return }
                if messageMonitorPaths.contains(self.rebaseWorkspace.rawMessageRepository?.workdir() ?? "") {
                    self.rebaseWorkspace.showRawMessageEditor = false
                    self.rebaseWorkspace.rawMessageRepository = nil
                    self.rebaseWorkspace.rawMessageText = ""
                }
                self.applyMultiRootRebaseResults(results, to: current)
            }
        } catch {
            messageMonitor.cancel()
            await MainActor.run {
                guard let current = self.rebaseWorkspace.multiRootSession,
                      current.id == sessionID else { return }
                self.multiRootWorkspace.running = false
                if messageMonitorPaths.contains(self.rebaseWorkspace.rawMessageRepository?.workdir() ?? "") {
                    self.rebaseWorkspace.showRawMessageEditor = false
                    self.rebaseWorkspace.rawMessageRepository = nil
                    self.rebaseWorkspace.rawMessageText = ""
                }
                self.feedbackCenter.error(
                    "Multi-root rebase failed",
                    detail: errorMessage(error),
                    nextStep: "Review the roots view before retrying.",
                    additionalActions: [
                        self.multiRootRebaseRecoveryFeedbackAction(.retry, sessionID: sessionID)
                    ],
                    notificationID: self.multiRootRebaseNotificationID()
                )
                self.feedbackCenter.attachResultRows(
                    multiRootRebaseFeedbackResultRows(for: current),
                    notificationID: self.multiRootRebaseNotificationID()
                )
            }
        }
    }
}

func applyMultiRootRebaseResults(
    _ results: [MultiRootRebaseResult],
    to session: MultiRootRebaseSession
) {
    let updated = updateMultiRootRebaseSession(session, with: results)
    rebaseWorkspace.multiRootSession = updated
    saveMultiRootRebaseSession(updated)
    multiRootWorkspace.running = false
    multiRootWorkspace.results = multiRootRebaseRows(for: updated)
    rebaseWorkspace.feedback = updated.roots
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    rebaseWorkspace.multiRootDrafts = []
    loadMultiRoots()

    if let paused = results.first(where: { $0.requiresFinish }) {
        let conflicts = paused.conflicts.isEmpty
            ? ""
            : "\n\(paused.conflicts.joined(separator: "、"))"
        feedbackCenter.warning(
            "Multi-root rebase paused",
            detail: "\(paused.displayName): \(paused.message)\(conflicts)",
            nextStep: "Resolve the root conflict, then use Continue or Abort from the roots view.",
            additionalActions: [
                multiRootRebaseRecoveryFeedbackAction(
                    .openRecovery,
                    rootPath: paused.rootPath,
                    sessionID: updated.id
                )
            ],
            notificationID: multiRootRebaseNotificationID()
        )
        openMultiRootConflictResolver(
            preferredRootPath: paused.rootPath,
            preferredPath: paused.conflicts.first
        )
    } else if let failure = results.first(where: { !$0.success && !$0.skipped }) {
        feedbackCenter.error(
            "Multi-root rebase partially completed",
            detail: "\(failure.displayName): \(failure.message)",
            nextStep: "Fix the failed root, then retry the remaining repositories.",
            additionalActions: [
                multiRootRebaseRecoveryFeedbackAction(.retry, sessionID: updated.id)
            ],
            notificationID: multiRootRebaseNotificationID()
        )
    } else if updated.roots.allSatisfy({ $0.state == .completed }) {
        let undoTargets = updated.roots.allSatisfy { !$0.updateRefs }
            ? multiRootRebaseRollbackTargets(for: updated)
            : []
        clearMultiRootRebaseSession(updated)
        rebaseWorkspace.multiRootSession = nil
        if undoTargets.count == updated.roots.count, !undoTargets.isEmpty {
            let undoAction = multiRootRebaseRecoveryFeedbackAction(
                .undo,
                rollbackTargets: undoTargets
            )
            feedbackCenter.success(
                "Multi-root rebase completed",
                detail: updated.projectPath,
                additionalActions: [undoAction],
                notificationID: multiRootRebaseNotificationID()
            )
        } else {
            feedbackCenter.success(
                "Multi-root rebase completed",
                detail: updated.projectPath,
                notificationID: multiRootRebaseNotificationID()
            )
        }
    }
    feedbackCenter.attachResultRows(
        multiRootRebaseFeedbackResultRows(for: updated),
        notificationID: multiRootRebaseNotificationID()
    )
}

func retryMultiRootRebase() {
    guard var session = rebaseWorkspace.multiRootSession else { return }
    for index in session.roots.indices where session.roots[index].state == .failed {
        session.roots[index].state = .pending
        session.roots[index].message = ""
    }
    rebaseWorkspace.multiRootSession = session
    saveMultiRootRebaseSession(session)
    runPendingMultiRootRebase(session)
}

func resumeMultiRootRebase() {
    guard let session = rebaseWorkspace.multiRootSession else { return }
    let sessionID = session.id
    Task.detached(priority: .utility) { [session] in
        let activeRoot = session.roots.compactMap { root -> String? in
            guard let rootRepo = try? openRepository(path: root.rootPath),
                  (try? rootRepo.operationState()) != nil else { return nil }
            return root.rootPath
        }.first
        await MainActor.run {
            guard self.rebaseWorkspace.multiRootSession?.id == sessionID else { return }
            if let activeRoot {
                self.openMultiRootConflictResolver(preferredRootPath: activeRoot)
                return
            }
            if session.roots.contains(where: { $0.state == .paused }) {
                self.feedbackCenter.error(
                    "Multi-root rebase recovery unavailable",
                    detail: "Git no longer reports the paused rebase state for this session.",
                    nextStep: "Inspect the affected roots and keep or restore the partial state manually."
                )
                return
            }
            var resumedSession = session
            for index in resumedSession.roots.indices where resumedSession.roots[index].state == .failed {
                resumedSession.roots[index].state = .pending
                resumedSession.roots[index].message = ""
            }
            self.rebaseWorkspace.multiRootSession = resumedSession
            saveMultiRootRebaseSession(resumedSession)
            self.runPendingMultiRootRebase(resumedSession)
        }
    }
}

}
