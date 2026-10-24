import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Git.FileActions > Checkin Files is scoped to the selected worktree file.
/// Keep the selection in the Commit workspace instead of silently opening the
/// first changed row in the repository.
func beginFileCheckin(_ path: String) {
    guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return }
    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    projectPanelExpanded = false
    shelfWorkspace.isWorkspaceTabActive = false
    fileWorkspace.previewPath = normalizedPath
    fileWorkspace.previewMode = .unstaged
    fileWorkspace.previewComparisonMode = nil
    fileWorkspace.previewThreeVersions = false
    fileWorkspace.previewVisible = true
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
}

func doCommit(forceChecks: Bool = false, rebaseAfterCommit: Bool = false) {
    guard let repo, !commitWorkspace.message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    let isRebaseEditAmend = commitWorkspace.amendMode && rebaseEditPauseAllowsAmend(operationRecovery.operation)
    guard operationRecovery.operation == nil || isRebaseEditAmend else { return }
    beginFeedbackOperation(commitWorkspace.amendMode ? "Amend commit" : "Commit")
    let msg = commitWorkspace.message
    let isAmend = commitWorkspace.amendMode
    let hooks = GitCommitHooksSettings.effectiveSkipHooks(requested: self.commitWorkspace.skipHooks)
    let checks = commitWorkspace.beforeCommitCommands
    let authorName = gitSettings.identityAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorEmail = gitSettings.identityAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerName = gitSettings.identityCommitterName.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerEmail = gitSettings.identityCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let signOff = gitSettings.identitySignOff
    let coAuthors = parseCoAuthors(gitSettings.identityCoAuthors)
    let pendingRebase = rebaseAfterCommit ? rebaseWorkspace.pendingAutoSquash : nil
    let operationProjectPath = projectWorkspace.path
    let operationRootPath = repo.workdir() ?? ""
    let operationRootLabel = operationRootPath.isEmpty
        ? ""
        : URL(fileURLWithPath: operationRootPath).lastPathComponent
    rememberCommitAuthor(
        name: authorName,
        email: authorEmail,
        projectPath: operationProjectPath
    )
    Task.detached(priority: .userInitiated) {
        do {
            // COMMIT-001 内置检查:身份缺失/未解决冲突(阻塞),大文件/CRLF/detached(警告)
            let builtin = try repo.commitChecksWithLargeFileLimit(
                maxFileSizeBytes: GitCommitWarningSettings.largeFileLimitBytes(
                    for: operationProjectPath
                )
            )
            let blocking = builtin.filter { $0.blocking }
            if !blocking.isEmpty {
                await MainActor.run {
                    self.commitWorkspace.pendingCommitAndPush = false
                    let kinds = blocking.map { $0.kind }.map { kind -> String in
                        switch kind {
                        case .identityMissing: return "Git 身份未配置 (user.name / user.email)"
                        case .unresolvedConflicts: return "存在未解决冲突"
                        default: return "提交被内置检查阻止"
                        }
                    }
                    self.feedbackCenter.error(
                        "Commit blocked",
                        detail: kinds.joined(separator: "\n"),
                        nextStep: "配置身份或解决冲突后重试。"
                    )
                    if blocking.contains(where: { $0.kind == .identityMissing }) {
                        self.gitSettings.pendingIdentityCommitRetry = true
                        self.gitSettings.showIdentitySettings = true
                    }
                }
                return
            }
            let warningPresentations = commitWarningPresentations(
                builtin,
                rootLabel: operationRootLabel,
                projectPath: operationProjectPath
            )
            if !warningPresentations.isEmpty {
                let decision = await MainActor.run {
                    presentCommitWarningDecision(
                        warningPresentations,
                        projectPath: operationProjectPath
                    )
                }
                guard decision.shouldContinue else {
                    await MainActor.run {
                        self.commitWorkspace.pendingCommitAndPush = false
                        self.commitWorkspace.feedback = "Commit cancelled"
                        self.feedbackCenter.warning(
                            "Commit cancelled",
                            detail: "Review the pre-commit warnings before committing.",
                            notificationID: operationRootLabel.isEmpty
                                ? nil
                                : self.commitNotificationID(rootPath: operationRootPath)
                        )
                    }
                    return
                }
                if decision.setCoreAutocrlf {
                    try? repo.setGlobalCoreAutocrlf()
                }
            }
            if !forceChecks {
                try runBeforeCommitChecks(repo: repo, commands: checks)
            }
            let identity = (try? repo.gitIdentity())
            let hasOverrides = !authorName.isEmpty || !authorEmail.isEmpty || !committerName.isEmpty || !committerEmail.isEmpty || signOff || !coAuthors.isEmpty
            let id = if identity?.signCommits == true || hasOverrides {
                try withArborPinentrySession {
                    try repo.commitWithOptions(
                        message: msg,
                        skipHooks: hooks,
                        authorName: authorName.isEmpty ? nil : authorName,
                        authorEmail: authorEmail.isEmpty ? nil : authorEmail,
                        committerName: committerName.isEmpty ? nil : committerName,
                        committerEmail: committerEmail.isEmpty ? nil : committerEmail,
                        signKey: identity?.signingKey,
                        signOff: signOff,
                        coAuthors: coAuthors,
                        amend: isAmend
                    )
                }
            } else if isAmend {
                try repo.amend(message: msg, skipHooks: hooks)
            } else {
                try repo.commit(message: msg, skipHooks: hooks)
            }
            let st = try repo.status(); let hid = repo.headCommitId()
            let repositoryPath = repo.workdir()
            let recent = (try? repo.recentCommitMessages(limit: 10)) ?? []
            let staging = try? repo.stagingModel()
            let branchList = (try? repo.branchList()) ?? []
            let syncStatuses = (try? repo.syncStatus()) ?? []
            await MainActor.run {
                self.repositoryStatus.entries = st; self.repositoryStatus.headId = hid
                self.repositoryStatus.stagingModel = staging
                self.repositoryStatus.lastIndexRevision = staging?.indexRevision
                self.branchWorkspace.branches = branchList
                self.branchWorkspace.syncStatuses = syncStatuses
                self.logSelectionState.detailCommit = nil
                if self.showsLogWorkspace {
                    // The Log workspace stays live beside Commit in Rebased;
                    // committing from the left pane must immediately move
                    // the graph and inspector to the new HEAD.
                    self.loadLog()
                }
                self.commitWorkspace.recentMessages = recent
                self.commitWorkspace.message = ""
                if isRebaseEditAmend {
                    self.refreshAll(showFeedback: false)
                    let recoveryActions = repositoryPath.flatMap { rootPath in
                        self.operationRecovery.operation.map {
                            self.operationRecoveryFeedbackActions(
                                state: $0,
                                rootPath: rootPath
                            )
                        }
                    } ?? []
                    self.commitWorkspace.feedback = "已 Amend rebase edit \(String(id.prefix(7)))"
                    self.feedbackCenter.success(
                        "Rebase commit amended",
                        detail: "\(String(id.prefix(7)))；请从恢复栏 Continue Rebase。",
                        additionalActions: recoveryActions,
                        notificationID: repositoryPath.map {
                            operationRecoveryNotificationID(rootPath: $0)
                        },
                        notificationGroup: .standard,
                        localized: false
                    )
                    return
                }
                let shouldOpenPushDialog = self.commitWorkspace.pendingCommitAndPush
                self.commitWorkspace.pendingCommitAndPush = false
                self.rebaseWorkspace.pendingAutoSquash = nil
                self.commitWorkspace.feedback = isAmend
                    ? "已 Amend \(String(id.prefix(7)))"
                    : "已提交 \(String(id.prefix(7)))"
                let rewordAction = repositoryPath.map {
                    self.commitRewordFeedbackAction(rootPath: $0, commitID: id)
                }
                self.feedbackCenter.success(
                    isAmend ? "Amend completed" : "Commit completed",
                    detail: String(id.prefix(7)),
                    additionalActions: rewordAction.map { [$0] } ?? [],
                    notificationID: repositoryPath.map(self.commitNotificationID)
                )
                if shouldOpenPushDialog, let repositoryPath {
                    self.beginSingleRootPushAfterCommit(rootPath: repositoryPath)
                }
                if let pendingRebase {
                    let hasResidualChanges = st.contains {
                        $0.staged != .unchanged
                            || $0.unstaged != .unchanged
                    }
                    if hasResidualChanges {
                        self.commitWorkspace.feedback = "已提交；为保护未提交改动，未自动变基"
                        self.feedbackCenter.warning(
                            "Commit completed; rebase skipped",
                            detail: "Uncommitted changes remain after the partial commit.",
                            nextStep: "Review or stash the remaining changes, then run the rebase again."
                        )
                    } else {
                        self.startAutoSquashRebase(
                            onto: pendingRebase.onto,
                            targetID: pendingRebase.targetID,
                            root: pendingRebase.root
                        )
                    }
                }
            }
        } catch {
            await MainActor.run {
                if let checkError = error as? BeforeCommitCheckError {
                    self.feedbackCenter.warning(
                        "Commit checks failed",
                        detail: "\(checkError.command)\n\n\(checkError.output)",
                        nextStep: "Review the check output, then retry or choose the force action."
                    )
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Before Commit checks failed")
                    alert.informativeText = String(localized: "\(checkError.command)\n\n\(checkError.output)")
                    alert.addButton(withTitle: String(localized: "Commit Anyway"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        self.doCommit(forceChecks: true, rebaseAfterCommit: rebaseAfterCommit)
                    } else {
                        self.commitWorkspace.pendingCommitAndPush = false
                    }
                    return
                }
                self.commitWorkspace.pendingCommitAndPush = false
                self.commitWorkspace.feedback = errorMessage(error)
                self.repositoryStatus.loadError = self.commitWorkspace.feedback
                let detail = errorMessage(error)
                if gitCommitSigningFailureNeedsGPGConfiguration(detail) {
                    self.feedbackCenter.error(
                        "Commit signing failed",
                        detail: detail,
                        nextStep: "Install GnuPG if needed, or configure a working pinentry program, then retry the commit.",
                        additionalActions: [self.gpgAgentSettingsFeedbackAction()],
                        notificationID: self.repo?.workdir().map(self.commitNotificationID)
                    )
                }
            }
        }
    }
}

/// IntelliJ's Git.Stage.ToggleCommitAll path: when nothing is staged, commit
/// all tracked worktree changes without adding untracked files implicitly.
/// The explicit Stage All action remains available for users who also want to
/// include untracked files.
func commitAllTrackedChanges() {
    guard let repo,
          !commitWorkspace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          repositoryStatus.entries.contains(where: {
              $0.staged != .conflicted
                  && $0.unstaged != .conflicted
                  && $0.unstaged != .unchanged
                  && $0.unstaged != .untracked
                  && $0.unstaged != .ignored
          }) else { return }
    beginFeedbackOperation("Commit all tracked changes")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.stageTracked()
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                self.doCommit()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Commit All failed",
                    detail: errorMessage(error),
                    nextStep: "Check the tracked changes and retry."
                )
            }
        }
    }
}

func rememberCommitAuthor(name: String, email: String, projectPath: String?) {
    guard let value = GitCommitAuthorHistorySettings.formattedAuthor(name: name, email: email) else {
        return
    }
    GitCommitAuthorHistorySettings.save(value, for: projectPath)
    gitSettings.identityRecentAuthors = GitCommitAuthorHistorySettings.authors(for: projectPath)
}

}
