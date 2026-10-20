import Foundation
import SwiftUI

/// 项目 Git 偏好、自动 fetch、身份、签名与 SSH 设置草稿。
@MainActor
final class GitSettingsState: ObservableObject {
    @Published var projectProtectedBranchPatterns: String?
    @Published var projectProtectedBranchSynchronize: Bool?
    @Published var projectIncomingCheckStrategyRaw: String?
    @Published var projectFetchTagsMode: GitFetchTagsModeChoice = .default
    @Published var projectUpdateMethod: GitUpdateMethodChoice = .merge
    @Published var autoFetchFailureFingerprint: String?
    @Published var autoFetchIncomingFingerprint: String?
    @Published var autoFetchIncomingBranches: Set<GitIncomingBranch> = []
    /// Each retry creates a new task generation. The monitor always performs
    /// its first check immediately, matching IntelliJ when a strategy is
    /// enabled or a project is activated.
    @Published var autoFetchRunGeneration = 0
    @Published var remoteProtectedBranchPatterns: [String] = []
    /// Hosted protection is repository-scoped. Keep it separate from the
    /// primary root's legacy presentation state so a multi-root push cannot
    /// accidentally use another repository's cached rules.
    @Published var remoteProtectedBranchPatternsByRoot: [String: [String]] = [:]
    @Published var gitSSHCommand = ""
    @Published var gitSSHKnownHostsFile = ""
    @Published var gitSSHIdentityFile = ""
    @Published var gitSSHHostKeyPolicy: SshHostKeyPolicy = .strict
    @Published var gitSSHAuthMethod: SshAuthMethod = .auto
    @Published var gitCredentialHelperConfig = ""
    @Published var gitCredentialHelpers: [CredentialHelperInfo] = []
    @Published var gitSSHAgentDiagnostics: SshAgentDiagnostics?
    @Published var identityName = ""
    @Published var identityEmail = ""
    @Published var identitySetNameEmailGlobally = GitIdentityScopeSettings.defaultSetNameEmailGlobally
    @Published var identitySigningKey = ""
    @Published var identitySigningFormat = "gpg"
    @Published var identitySignCommits = false
    @Published var identityAuthorName = ""
    @Published var identityAuthorEmail = ""
    @Published var identityRecentAuthors: [String] = []
    @Published var identityCommitterName = ""
    @Published var identityCommitterEmail = ""
    @Published var identitySignOff = false
    @Published var identityCoAuthors = ""
    @Published var showProjectGitSettings = false
    @Published var showUpdateProjectOptions = false
    @Published var showIdentitySettings = false
    @Published var pendingIdentityCommitRetry = false
    @Published var showGpgAgentSettings = false
    @Published var showGitSSHSettings = false
    @Published var lastSuccessfulSSHAuthentications: [SSHAuthenticationRecord] = []
}
