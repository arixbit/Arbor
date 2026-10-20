import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Keep missing-identity recovery on the same durable VCS notification as the
/// failed commit. The action only opens the settings surface; the user still
/// explicitly chooses the identity scope and saves the values.
func identitySettingsFeedbackAction() -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .openIdentitySettings,
        projectPath: projectPath,
        rootPath: nil,
        shelfName: ""
    )
    return FeedbackAction(
        id: "open-identity-settings",
        title: "Configure Git Identity…",
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func loadGitSSHSettings() {
    guard let repo else { return }
    let lastSuccessfulAuthentications = credentialAuth.sshAuthenticationRecords()
    Task.detached(priority: .userInitiated) {
        do {
            let settings = try repo.sshConnectionSettings()
            let credentialHelperConfig = (try? repo.credentialHelperConfig()) ?? []
            let credentialHelpers = (try? repo.credentialHelpers()) ?? []
            let sshAgentDiagnostics = try? repo.sshAgentDiagnostics()
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.gitSSHCommand = settings.command
                self.gitSSHKnownHostsFile = settings.knownHostsFile
                self.gitSSHIdentityFile = settings.identityFile
                self.gitSSHHostKeyPolicy = settings.hostKeyPolicy
                self.gitSSHAuthMethod = settings.authMethod
                self.gitCredentialHelperConfig = credentialHelperConfig.joined(separator: "\n")
                self.gitCredentialHelpers = credentialHelpers
                self.gitSSHAgentDiagnostics = sshAgentDiagnostics
                self.lastSuccessfulSSHAuthentications = lastSuccessfulAuthentications
                self.showGitSSHSettings = true
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load SSH settings failed",
                    detail: errorMessage(error),
                    nextStep: "确认当前项目是一个可写的 Git 工作区。"
                )
            }
        }
    }
}

func loadGitSSHAgentDiagnostics() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        let diagnostics = try? repo.sshAgentDiagnostics()
        await MainActor.run {
            guard self.projectRepo === repo else { return }
            self.gitSSHAgentDiagnostics = diagnostics
        }
    }
}

func saveGitSSHSettings() {
    guard let repo else { return }
    let command = gitSSHCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    let knownHostsFile = gitSSHKnownHostsFile.trimmingCharacters(in: .whitespacesAndNewlines)
    let identityFile = gitSSHIdentityFile.trimmingCharacters(in: .whitespacesAndNewlines)
    let hostKeyPolicy = gitSSHHostKeyPolicy
    let authMethod = gitSSHAuthMethod
    let helperValues = gitCredentialHelperConfig
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    beginFeedbackOperation("Save SSH and credential settings")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.setSshConnectionSettings(
                command: command,
                knownHostsFile: knownHostsFile,
                identityFile: identityFile,
                hostKeyPolicy: hostKeyPolicy,
                authMethod: authMethod
            )
            try repo.setCredentialHelperConfig(helpers: helperValues)
            let credentialHelpers = (try? repo.credentialHelpers()) ?? []
            let sshAgentDiagnostics = try? repo.sshAgentDiagnostics()
            await MainActor.run {
                self.gitCredentialHelpers = credentialHelpers
                self.gitSSHAgentDiagnostics = sshAgentDiagnostics
                self.feedbackCenter.success(
                    "SSH and credential settings saved",
                    detail: command.isEmpty
                        ? "Using the configured SSH defaults"
                        : command
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Save SSH and credential settings failed",
                    detail: errorMessage(error),
                    nextStep: "检查 SSH 与 credential.helper 每行一项后重试。"
                )
            }
        }
    }
}

/// Keep the project-level commit draft isolated from the persistent identity
/// settings sheet, while reflecting values saved there when it closes.
func syncMultiRootCommitIdentityDraftFromSettings() {
    multiRootCommitAuthorName = identityAuthorName
    multiRootCommitAuthorEmail = identityAuthorEmail
    multiRootCommitCommitterName = identityCommitterName
    multiRootCommitCommitterEmail = identityCommitterEmail
    multiRootCommitSignOff = identitySignOff
    multiRootCommitCoAuthors = identityCoAuthors
}

func setGitIdentity() {
    guard let repo else { return }
    let name = identityName.trimmingCharacters(in: .whitespacesAndNewlines)
    let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !email.isEmpty else {
        loadError = "Git identity requires both name and email."
        return
    }
    let signingKey = identitySigningKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let signingFormat = identitySigningFormat == "ssh" ? "ssh" : "gpg"
    let signCommits = identitySignCommits
    let setNameEmailGlobally = identitySetNameEmailGlobally
    let authorName = identityAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorEmail = identityAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerName = identityCommitterName.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerEmail = identityCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let signOff = identitySignOff
    let coAuthors = identityCoAuthors
    beginFeedbackOperation("Save Git identity")
    Task.detached(priority: .userInitiated) {
        do {
            if setNameEmailGlobally {
                try repo.setGitIdentityWithGlobalNameEmail(
                    name: name,
                    email: email,
                    signingKey: signingKey.isEmpty ? nil : signingKey,
                    signingFormat: signingKey.isEmpty ? nil : signingFormat,
                    signCommits: signCommits
                )
            } else {
                try repo.setGitIdentity(
                    name: name,
                    email: email,
                    signingKey: signingKey.isEmpty ? nil : signingKey,
                    signingFormat: signingKey.isEmpty ? nil : signingFormat,
                    signCommits: signCommits
                )
            }
            await MainActor.run {
                GitIdentityScopeSettings.saveSetNameEmailGlobally(
                    setNameEmailGlobally,
                    for: self.projectPath
                )
                self.identityAuthorName = authorName
                self.identityAuthorEmail = authorEmail
                self.identityCommitterName = committerName
                self.identityCommitterEmail = committerEmail
                self.identitySignOff = signOff
                self.identityCoAuthors = coAuthors
                GitSignOffCommitSettings.saveGlobal(signOff)
                UserDefaults.standard.set(authorName, forKey: "arbor.identity.authorName")
                UserDefaults.standard.set(authorEmail, forKey: "arbor.identity.authorEmail")
                UserDefaults.standard.set(committerName, forKey: "arbor.identity.committerName")
                UserDefaults.standard.set(committerEmail, forKey: "arbor.identity.committerEmail")
                UserDefaults.standard.set(signOff, forKey: "arbor.identity.signOff")
                UserDefaults.standard.set(coAuthors, forKey: "arbor.identity.coAuthors")
                self.feedbackCenter.success("Git identity saved")
                if self.pendingIdentityCommitRetry {
                    self.pendingIdentityCommitRetry = false
                    DispatchQueue.main.async {
                        self.doCommit()
                    }
                }
            }
        } catch {
            await MainActor.run { self.feedbackCenter.error("Git identity failed", detail: errorMessage(error)) }
        }
    }
}

}
