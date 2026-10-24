import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Open the project-level Changes Browser without widening the write boundary
/// of the existing single-root commit workspace.
func openMultiRootCommitDialog(_ selectedChanges: [MultiRootChangeSelection]? = nil) {
    commitWorkspace.multiRootSelectedPaths = selectedChanges
    commitWorkspace.multiRootMessage = ""
    commitWorkspace.multiRootRecentMessages = []
    commitWorkspace.multiRootAmendMode = false
    commitWorkspace.multiRootSkipHooks = commitWorkspace.skipHooks
    commitWorkspace.multiRootAuthorName = gitSettings.identityAuthorName
    commitWorkspace.multiRootAuthorEmail = gitSettings.identityAuthorEmail
    commitWorkspace.multiRootCommitterName = gitSettings.identityCommitterName
    commitWorkspace.multiRootCommitterEmail = gitSettings.identityCommitterEmail
    commitWorkspace.multiRootSignOff = gitSettings.identitySignOff
    commitWorkspace.multiRootCoAuthors = gitSettings.identityCoAuthors
    commitWorkspace.showMultiRootDialog = true
    loadMultiRootChanges()
    loadMultiRootCommitMetadata(rootPaths: multiRootWorkspace.roots.map(\.path))
}

func currentMultiRootCommitOptions() -> MultiRootCommitOptions {
    MultiRootCommitOptions(
        skipHooks: commitWorkspace.multiRootSkipHooks,
        authorName: commitWorkspace.multiRootAuthorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootAuthorName.trimmingCharacters(in: .whitespacesAndNewlines),
        authorEmail: commitWorkspace.multiRootAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines),
        committerName: commitWorkspace.multiRootCommitterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootCommitterName.trimmingCharacters(in: .whitespacesAndNewlines),
        committerEmail: commitWorkspace.multiRootCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : commitWorkspace.multiRootCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines),
        signOff: commitWorkspace.multiRootSignOff,
        coAuthors: parseCoAuthors(commitWorkspace.multiRootCoAuthors),
        amend: commitWorkspace.multiRootAmendMode,
        runBeforeCommitChecks: true,
        beforeCommitCommands: commitWorkspace.beforeCommitCommands.map {
            MultiRootCommitCheck(command: $0.command, args: $0.args)
        }
    )
}

/// Commit a validated message only in the repositories explicitly selected by
/// the project-level Commit dialog. The engine returns a root-qualified
/// partial result, including clean and unselected roots as skipped entries.
func commitMultiRootSelectedRoots(_ rootPaths: [String], _ message: String) {
    let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootPaths.isEmpty, !commitMessage.isEmpty else { return }

    let options = currentMultiRootCommitOptions()

    performMultiRootCommit(
        rootPaths: rootPaths,
        message: commitMessage,
        options: options,
        allowForceRetry: true,
        pushAfterCommit: false
    )
}

/// Commit only the root-qualified files selected in the project-level Changes
/// Browser. The selected rows are normalized before crossing the FFI boundary
/// so identical relative paths in different Git roots remain independent.
func commitMultiRootSelectedChanges(
    _ selectedChanges: [MultiRootChangeSelection],
    _ message: String
) {
    let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedChanges = normalizedMultiRootCommitSelections(selectedChanges)
    guard !normalizedChanges.isEmpty, !commitMessage.isEmpty else { return }

    performMultiRootCommit(
        rootPaths: Array(Set(normalizedChanges.map(\.rootPath))).sorted(),
        message: commitMessage,
        options: currentMultiRootCommitOptions(),
        allowForceRetry: true,
        pushAfterCommit: false,
        selectedChanges: normalizedChanges
    )
}

/// Execute a project-level commit and, when a custom before-commit command
/// fails, offer IntelliJ's explicit Commit Anyway decision for only those
/// roots. Built-in identity/conflict checks remain enforced by Rust.
func performMultiRootCommit(
    rootPaths: [String],
    message: String,
    options requestedOptions: MultiRootCommitOptions,
    allowForceRetry: Bool,
    pushAfterCommit: Bool = false,
    priorPushRootPaths: [String] = [],
    selectedChanges: [MultiRootChangeSelection]? = nil
) {
    guard !rootPaths.isEmpty, !message.isEmpty, let projectPath = projectWorkspace.path else { return }
    var options = requestedOptions
    options.skipHooks = GitCommitHooksSettings.effectiveSkipHooks(
        requested: requestedOptions.skipHooks
    )
    commitWorkspace.showMultiRootDialog = false
    multiRootWorkspace.running = true
    beginFeedbackOperation(
        "Multi-root commit",
        notificationID: multiRootRetryNotificationID(.commit)
    )
    rememberCommitAuthor(
        name: options.authorName ?? "",
        email: options.authorEmail ?? "",
        projectPath: projectPath
    )

    Task.detached(priority: .userInitiated) { [options] in
        do {
            let warningPresentations = try collectMultiRootCommitWarnings(
                rootPaths: rootPaths,
                selectedChanges: selectedChanges,
                projectPath: projectPath
            )
            var setCoreAutocrlf = false
            if !warningPresentations.isEmpty {
                let decision = await MainActor.run {
                    presentCommitWarningDecision(
                        warningPresentations,
                        projectPath: projectPath
                    )
                }
                guard decision.shouldContinue else {
                    await MainActor.run {
                        self.multiRootWorkspace.running = false
                        self.feedbackCenter.warning(
                            "Multi-root Commit cancelled",
                            detail: "Review the pre-commit warnings before committing.",
                            notificationID: self.multiRootRetryNotificationID(.commit)
                        )
                    }
                    return
                }
                setCoreAutocrlf = decision.setCoreAutocrlf
            }
            if setCoreAutocrlf, let rootPath = rootPaths.first,
               let warningRepository = try? openRepository(path: rootPath) {
                // Match IntelliJ's non-blocking CRLF fix: a config failure
                // leaves the warning enabled for the next commit, but must
                // not turn an otherwise valid commit into a failed commit.
                try? warningRepository.setGlobalCoreAutocrlf()
            }
            let results = try withArborPinentrySession {
                if let selectedChanges {
                    return try runMultiRootCommitSelectedPathsWithOptions(
                        scanRoot: projectPath,
                        selections: makeLiveMultiRootCommitSelections(selectedChanges),
                        commitMessage: message,
                        options: options
                    )
                }
                return try runMultiRootCommitWithOptions(
                    scanRoot: projectPath,
                    rootPaths: rootPaths,
                    commitMessage: message,
                    options: options
                )
            }
            let committedHeadIDs = Self.headCommitIDs(
                for: results
                    .filter { $0.success && !$0.skipped }
                    .map(\.rootPath)
            )
            await MainActor.run {
                let checkFailures = results.filter {
                    !$0.success && $0.message.contains("before-commit check")
                }
                let failedRootPaths = results.filter { !$0.success }.map(\.rootPath)
                let committedRootPaths = results
                    .filter { $0.success && !$0.skipped }
                    .map(\.rootPath)
                let pushRootPaths = Array(Set(priorPushRootPaths + committedRootPaths)).sorted()
                let retryAction = failedRootPaths.isEmpty
                    ? nil
                    : self.multiRootCommitRetryFeedbackAction(
                        rootPaths: failedRootPaths,
                        message: message,
                        options: options,
                        pushAfterCommit: pushAfterCommit,
                        pushRootPaths: pushAfterCommit ? pushRootPaths : [],
                        selectedChanges: selectedChanges?.filter {
                            failedRootPaths.contains($0.rootPath)
                        }
                    )
                let pushAction = pushAfterCommit && !pushRootPaths.isEmpty
                    ? self.multiRootCommitPushFeedbackAction(rootPaths: pushRootPaths)
                    : nil
                let signingActions = results.contains(where: {
                    !$0.success && gitCommitSigningFailureNeedsGPGConfiguration($0.message)
                }) ? [self.gpgAgentSettingsFeedbackAction()] : []
                let identityActions = results.contains(where: {
                    !$0.success && $0.message.localizedCaseInsensitiveContains("git identity missing")
                }) ? [self.identitySettingsFeedbackAction()] : []
                let rewordActions = committedRootPaths.compactMap { rootPath -> FeedbackAction? in
                    guard let commitID = committedHeadIDs[rootPath], !commitID.isEmpty else {
                        return nil
                    }
                    return self.commitRewordFeedbackAction(
                        rootPath: rootPath,
                        commitID: commitID
                    )
                }
                self.multiRootWorkspace.results = results
                self.multiRootWorkspace.running = false
                if allowForceRetry && options.runBeforeCommitChecks && !checkFailures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Commit checks failed")
                    alert.informativeText = checkFailures.map {
                        "\($0.displayName): \($0.message)"
                    }.joined(separator: "\n")
                    alert.addButton(withTitle: "Commit Anyway")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        var forcedOptions = options
                        forcedOptions.runBeforeCommitChecks = false
                        self.performMultiRootCommit(
                            rootPaths: checkFailures.map(\.rootPath),
                            message: message,
                            options: forcedOptions,
                            allowForceRetry: false,
                            pushAfterCommit: pushAfterCommit,
                            priorPushRootPaths: pushRootPaths,
                            selectedChanges: selectedChanges?.filter {
                                checkFailures.map(\.rootPath).contains($0.rootPath)
                            }
                        )
                    } else {
                        var additionalActions = rewordActions
                        if let retryAction {
                            additionalActions.append(retryAction)
                        }
                        if let pushAction {
                            additionalActions.append(pushAction)
                        }
                        self.feedbackCenter.warning(
                            "Commit checks failed",
                            detail: alert.informativeText,
                            nextStep: "Fix the checks or choose Commit Anyway for the failed roots.",
                            additionalActions: additionalActions,
                            notificationID: self.multiRootRetryNotificationID(.commit)
                        )
                        self.feedbackCenter.attachResultRows(
                            feedbackResultRows(from: results),
                            notificationID: self.multiRootRetryNotificationID(.commit)
                        )
                        if shouldAutomaticallyOpenMultiRootCommitPushOptions(
                            pushAfterCommit: pushAfterCommit,
                            pushRootPaths: pushRootPaths,
                            failedRootPaths: failedRootPaths
                        ) {
                            self.beginMultiRootCommitPush(rootPaths: pushRootPaths)
                        }
                        self.refreshAll(showFeedback: false)
                        self.loadMultiRoots(onCompleted: self.loadMultiRootChanges)
                    }
                    return
                }

                let committed = results.filter { $0.success && !$0.skipped }.count
                let failed = results.filter { !$0.success }.count
                let skipped = results.filter { $0.skipped }.count
                let detail = "\(committed) committed · \(failed) failed · \(skipped) skipped"
                var additionalActions = rewordActions
                additionalActions.append(contentsOf: signingActions)
                additionalActions.append(contentsOf: identityActions)
                if let retryAction {
                    additionalActions.append(retryAction)
                }
                if let pushAction {
                    additionalActions.append(pushAction)
                }
                if failed == 0 {
                    self.feedbackCenter.success(
                        "Multi-root commit complete",
                        detail: detail,
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit)
                    )
                } else {
                    self.feedbackCenter.warning(
                        "Multi-root commit partially completed",
                        detail: detail,
                        nextStep: "Review the failed roots and retry the selected commit.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit)
                    )
                }
                self.feedbackCenter.attachResultRows(
                    feedbackResultRows(from: results),
                    notificationID: self.multiRootRetryNotificationID(.commit)
                )
                if shouldAutomaticallyOpenMultiRootCommitPushOptions(
                    pushAfterCommit: pushAfterCommit,
                    pushRootPaths: pushRootPaths,
                    failedRootPaths: failedRootPaths
                ) {
                    self.beginMultiRootCommitPush(rootPaths: pushRootPaths)
                }
                self.refreshAll(showFeedback: false)
                self.loadMultiRoots(onCompleted: self.loadMultiRootChanges)
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                let retryAction = self.multiRootCommitRetryFeedbackAction(
                    rootPaths: rootPaths,
                    message: message,
                    options: options,
                    pushAfterCommit: pushAfterCommit,
                    pushRootPaths: pushAfterCommit ? priorPushRootPaths : [],
                    selectedChanges: selectedChanges
                )
                var additionalActions = [retryAction]
                let detail = errorMessage(error)
                if gitCommitSigningFailureNeedsGPGConfiguration(detail) {
                    additionalActions.append(self.gpgAgentSettingsFeedbackAction())
                }
                if pushAfterCommit && !priorPushRootPaths.isEmpty {
                    additionalActions.append(
                        self.multiRootCommitPushFeedbackAction(rootPaths: priorPushRootPaths)
                    )
                }
                if let engineError = error as? EngineError, case .Cancelled = engineError {
                    self.feedbackCenter.warning(
                        "Multi-root commit canceled",
                        detail: "The selected roots were kept for an explicit retry.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit),
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        "Multi-root commit failed",
                        detail: detail,
                        nextStep: "Check the commit message and selected roots, then retry.",
                        additionalActions: additionalActions,
                        notificationID: self.multiRootRetryNotificationID(.commit)
                    )
                }
            }
        }
    }
}

/// Load recent messages from all discovered roots so the aggregate dialog
/// never silently presents the primary repository's history as every root's.
func loadMultiRootCommitMetadata(rootPaths: [String]) {
    let paths = Array(Set(rootPaths)).sorted()
    Task.detached(priority: .utility) {
        var messages: [String] = []
        for path in paths {
            guard let rootRepo = try? openRepository(path: path) else { continue }
            messages.append(contentsOf: (try? rootRepo.recentCommitMessages(limit: 10)) ?? [])
        }
        var seen = Set<String>()
        let unique = messages.filter { seen.insert($0).inserted }
        await MainActor.run {
            self.commitWorkspace.multiRootRecentMessages = unique
        }
    }
}

/// Apply the first configured template from the selected roots in stable
/// order. A single project-level message cannot represent multiple different
/// repository templates, so the choice is deterministic and visible.
func loadMultiRootCommitTemplate(_ rootPaths: [String]) {
    let paths = Array(Set(rootPaths)).sorted()
    Task.detached(priority: .userInitiated) {
        var template: String?
        for path in paths {
            guard let rootRepo = try? openRepository(path: path),
                  let candidate = try? rootRepo.commitTemplate(),
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            template = candidate
            break
        }
        let selectedTemplate = template
        await MainActor.run {
            if let selectedTemplate {
                self.commitWorkspace.multiRootMessage = selectedTemplate
            } else {
                self.feedbackCenter.warning(
                    "No commit template configured",
                    detail: "None of the selected Git roots exposes a non-empty commit.template."
                )
            }
        }
    }
}

func multiRootCommitRetryFeedbackAction(
    rootPaths: [String],
    message: String,
    options: MultiRootCommitOptions,
    pushAfterCommit: Bool = false,
    pushRootPaths: [String] = [],
    selectedChanges: [MultiRootChangeSelection]? = nil
) -> FeedbackAction {
    let normalizedSelectedChanges = selectedChanges.map(normalizedMultiRootCommitSelections)
    let request = makeMultiRootRetryRequest(
        operation: .commit,
        rootPaths: rootPaths,
        commitRetry: PersistedMultiRootCommitRetry(
            message: message,
            options: options,
            pushAfterCommit: pushAfterCommit,
            pushRootPaths: pushRootPaths,
            selectedPaths: normalizedSelectedChanges?.map(PersistedMultiRootChangePath.init)
        )
    )
    return FeedbackAction(
        id: "retry-multi-root-commit:\(rootPaths.sorted().joined(separator: "|")):\(normalizedSelectedChanges?.map(\.id).joined(separator: "|") ?? "roots")",
        title: "Retry Failed Commits",
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

nonisolated func normalizedMultiRootCommitSelections(
    _ selections: [MultiRootChangeSelection]
) -> [MultiRootChangeSelection] {
    var seen = Set<String>()
    return selections
        .filter {
            !$0.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .filter { seen.insert($0.id).inserted }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.path < $1.path }
            return $0.rootPath < $1.rootPath
        }
}

nonisolated func makeLiveMultiRootCommitSelections(
    _ selections: [MultiRootChangeSelection]
) -> [MultiRootCommitSelection] {
    let normalized = normalizedMultiRootCommitSelections(selections)
    let grouped = Dictionary(grouping: normalized, by: \.rootPath)
    return grouped.keys.sorted().map { rootPath in
        let paths = grouped[rootPath, default: []]
            .map(\.path)
        return MultiRootCommitSelection(
            rootPath: rootPath,
            paths: Array(Set(paths)).sorted()
        )
    }
}

}
