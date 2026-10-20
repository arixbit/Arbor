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
        projectPath: projectWorkspace.path,
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
                guard self.projectWorkspace.repository === repo else { return }
                self.gitSettings.gitSSHCommand = settings.command
                self.gitSettings.gitSSHKnownHostsFile = settings.knownHostsFile
                self.gitSettings.gitSSHIdentityFile = settings.identityFile
                self.gitSettings.gitSSHHostKeyPolicy = settings.hostKeyPolicy
                self.gitSettings.gitSSHAuthMethod = settings.authMethod
                self.gitSettings.gitCredentialHelperConfig = credentialHelperConfig.joined(separator: "\n")
                self.gitSettings.gitCredentialHelpers = credentialHelpers
                self.gitSettings.gitSSHAgentDiagnostics = sshAgentDiagnostics
                self.gitSettings.lastSuccessfulSSHAuthentications = lastSuccessfulAuthentications
                self.gitSettings.showGitSSHSettings = true
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
            guard self.projectWorkspace.repository === repo else { return }
            self.gitSettings.gitSSHAgentDiagnostics = diagnostics
        }
    }
}

func saveGitSSHSettings() {
    guard let repo else { return }
    let command = gitSettings.gitSSHCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    let knownHostsFile = gitSettings.gitSSHKnownHostsFile.trimmingCharacters(in: .whitespacesAndNewlines)
    let identityFile = gitSettings.gitSSHIdentityFile.trimmingCharacters(in: .whitespacesAndNewlines)
    let hostKeyPolicy = gitSettings.gitSSHHostKeyPolicy
    let authMethod = gitSettings.gitSSHAuthMethod
    let helperValues = gitSettings.gitCredentialHelperConfig
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
                self.gitSettings.gitCredentialHelpers = credentialHelpers
                self.gitSettings.gitSSHAgentDiagnostics = sshAgentDiagnostics
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
    commitWorkspace.multiRootAuthorName = gitSettings.identityAuthorName
    commitWorkspace.multiRootAuthorEmail = gitSettings.identityAuthorEmail
    commitWorkspace.multiRootCommitterName = gitSettings.identityCommitterName
    commitWorkspace.multiRootCommitterEmail = gitSettings.identityCommitterEmail
    commitWorkspace.multiRootSignOff = gitSettings.identitySignOff
    commitWorkspace.multiRootCoAuthors = gitSettings.identityCoAuthors
}

func setGitIdentity() {
    guard let repo else { return }
    let name = gitSettings.identityName.trimmingCharacters(in: .whitespacesAndNewlines)
    let email = gitSettings.identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !email.isEmpty else {
        repositoryStatus.loadError = "Git identity requires both name and email."
        return
    }
    let signingKey = gitSettings.identitySigningKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let signingFormat = gitSettings.identitySigningFormat == "ssh" ? "ssh" : "gpg"
    let signCommits = gitSettings.identitySignCommits
    let setNameEmailGlobally = gitSettings.identitySetNameEmailGlobally
    let authorName = gitSettings.identityAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorEmail = gitSettings.identityAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerName = gitSettings.identityCommitterName.trimmingCharacters(in: .whitespacesAndNewlines)
    let committerEmail = gitSettings.identityCommitterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    let signOff = gitSettings.identitySignOff
    let coAuthors = gitSettings.identityCoAuthors
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
                    for: self.projectWorkspace.path
                )
                self.gitSettings.identityAuthorName = authorName
                self.gitSettings.identityAuthorEmail = authorEmail
                self.gitSettings.identityCommitterName = committerName
                self.gitSettings.identityCommitterEmail = committerEmail
                self.gitSettings.identitySignOff = signOff
                self.gitSettings.identityCoAuthors = coAuthors
                GitSignOffCommitSettings.saveGlobal(signOff)
                UserDefaults.standard.set(authorName, forKey: "arbor.identity.authorName")
                UserDefaults.standard.set(authorEmail, forKey: "arbor.identity.authorEmail")
                UserDefaults.standard.set(committerName, forKey: "arbor.identity.committerName")
                UserDefaults.standard.set(committerEmail, forKey: "arbor.identity.committerEmail")
                UserDefaults.standard.set(signOff, forKey: "arbor.identity.signOff")
                UserDefaults.standard.set(coAuthors, forKey: "arbor.identity.coAuthors")
                self.feedbackCenter.success("Git identity saved")
                if self.gitSettings.pendingIdentityCommitRetry {
                    self.gitSettings.pendingIdentityCommitRetry = false
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
