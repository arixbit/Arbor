import SwiftUI
import AppKit

@MainActor
final class GitHubWorkspaceModel: ObservableObject {
    let client: GitHubClient
    let repository: HostingRepository?

    @Published var pullRequests: [GitHubPullRequest] = []
    @Published var issues: [GitHubIssue] = []
    @Published var lastError: GitHubAPIError?
    @Published var showAuthenticationPrompt = false
    @Published var isLoading = false

    init(repository: HostingRepository?, client: GitHubClient = GitHubClient()) {
        self.repository = repository
        self.client = client
    }

    func loadAll() async {
        guard repository != nil else { return }
        isLoading = true
        await loadPullRequests()
        await loadIssues()
        isLoading = false
    }

    func loadPullRequests(state: String = "open") async {
        guard let repository else { return }
        do {
            pullRequests = try await client.listPullRequests(for: repository, state: state)
            lastError = nil
        } catch {
            record(error)
        }
    }

    func loadIssues(state: String = "open") async {
        guard let repository else { return }
        do {
            issues = try await client.listIssues(for: repository, state: state)
            lastError = nil
        } catch {
            record(error)
        }
    }

    func createPullRequest(title: String, body: String, head: String, base: String) async -> Bool {
        guard let repository else { return false }
        do {
            _ = try await client.createPullRequest(
                for: repository,
                title: title,
                body: body.isEmpty ? nil : body,
                head: head,
                base: base
            )
            await loadPullRequests()
            return true
        } catch {
            record(error)
            return false
        }
    }

    func createIssue(title: String, body: String) async -> Bool {
        guard let repository else { return false }
        do {
            _ = try await client.createIssue(
                for: repository,
                title: title,
                body: body.isEmpty ? nil : body
            )
            await loadIssues()
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func record(_ error: Error) {
        let apiError = (error as? GitHubAPIError)
            ?? GitHubAPIError.transport(message: error.localizedDescription)
        lastError = apiError
        if apiError.isAuthenticationFailure {
            showAuthenticationPrompt = true
        }
    }
}

@MainActor
final class HostingWorkspaceModel: ObservableObject {
    let client: any HostingClient
    let repository: HostingRepository?

    @Published var pullRequests: [HostingPullRequest] = []
    @Published var issues: [HostingIssue] = []
    @Published var lastError: String?
    @Published var showAuthenticationPrompt = false
    @Published var isLoading = false

    init(repository: HostingRepository?) {
        self.repository = repository
        self.client = repository.map { HostingClientFactory.make(for: $0) } ?? GitHubClient()
    }

    var providerTitle: String {
        repository?.provider.rawValue.capitalized ?? "Hosting"
    }

    func loadAll() async {
        guard repository != nil else { return }
        isLoading = true
        await loadPullRequests()
        await loadIssues()
        isLoading = false
    }

    func loadPullRequests(state: String = "open") async {
        guard let repository else { return }
        do {
            pullRequests = try await client.listHostingPullRequests(for: repository, state: state)
            lastError = nil
        } catch {
            record(error)
        }
    }

    func loadIssues(state: String = "open") async {
        guard let repository else { return }
        do {
            issues = try await client.listHostingIssues(for: repository, state: state)
            lastError = nil
        } catch {
            record(error)
        }
    }

    func createPullRequest(title: String, body: String, head: String, base: String) async -> Bool {
        guard let repository else { return false }
        do {
            _ = try await client.createHostingPullRequest(
                for: repository,
                title: title,
                body: body.isEmpty ? nil : body,
                head: head,
                base: base
            )
            await loadPullRequests()
            return true
        } catch {
            record(error)
            return false
        }
    }

    func createIssue(title: String, body: String) async -> Bool {
        guard let repository else { return false }
        do {
            _ = try await client.createHostingIssue(
                for: repository,
                title: title,
                body: body.isEmpty ? nil : body
            )
            await loadIssues()
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func record(_ error: Error) {
        lastError = error.localizedDescription
        if let githubError = error as? GitHubAPIError {
            showAuthenticationPrompt = githubError.isAuthenticationFailure
        } else if let hostingError = error as? HostingAPIError {
            showAuthenticationPrompt = hostingError.isAuthenticationFailure
        }
    }
}

enum HostingSection: String, CaseIterable, Identifiable {
    case pullRequests
    case issues

    var id: String { rawValue }
}

struct HostingSidebarView: View {
    let repository: HostingRepository?
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(repository?.provider.rawValue.capitalized ?? "Hosting", systemImage: "arrow.triangle.branch")
                .font(.headline)
            if let repository {
                Text(repository.fullName)
                    .font(.system(.body, design: .monospaced))
                Text(repository.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Pull requests and issues are shown in the detail panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Settings") { showSettings = true }
            } else {
                Text("No supported hosting remote is configured.")
                    .foregroundStyle(.secondary)
                Text("Add a GitHub, GitLab, or Bitbucket remote to enable PRs and issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }
}

struct HostingHubView: View {
    let repository: HostingRepository?
    @Binding var showSettings: Bool
    @StateObject private var model: HostingWorkspaceModel
    @State private var section: HostingSection = .pullRequests
    @State private var pullRequestState = "open"
    @State private var issueState = "open"
    @State private var showCreatePullRequest = false
    @State private var showCreateIssue = false

    init(remoteURL: String?, showSettings: Binding<Bool>) {
        let repository = remoteURL.flatMap { HostingProvider.parse(remoteURL: $0) }
        self.repository = repository
        self._showSettings = showSettings
        self._model = StateObject(wrappedValue: HostingWorkspaceModel(repository: repository))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(model.providerTitle, systemImage: "arrow.triangle.branch")
                    .font(.title2.bold())
                if let repository {
                    Text(repository.fullName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings") { showSettings = true }
                    .disabled(repository == nil)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            Divider()

            if repository == nil {
                ContentUnavailableView(
                    "No supported hosting remote configured",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("Add a GitHub remote before using PRs or issues.")
                )
            } else {
                Picker("Hosting", selection: $section) {
                    Text("Pull Requests").tag(HostingSection.pullRequests)
                    Text("Issues").tag(HostingSection.issues)
                }
                .pickerStyle(.segmented)
                .padding(12)
                switch section {
                case .pullRequests:
                    pullRequestsPanel
                case .issues:
                    issuesPanel
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: repository?.fullName) {
            await model.loadAll()
        }
        .alert("Hosting authentication required", isPresented: $model.showAuthenticationPrompt) {
            Button("Configure token") { showSettings = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(model.lastError ?? "Configure a token in Settings to continue.")
        }
        .sheet(isPresented: $showCreatePullRequest) {
            PullRequestCreateView(defaultBase: "main") { title, body, head, base in
                await model.createPullRequest(title: title, body: body, head: head, base: base)
            }
        }
        .sheet(isPresented: $showCreateIssue) {
            IssueCreateView { title, body in
                await model.createIssue(title: title, body: body)
            }
        }
    }

    private var pullRequestsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("State", selection: $pullRequestState) {
                    Text("Open").tag("open")
                    Text("Closed").tag("closed")
                    Text("All").tag("all")
                }
                .frame(width: 150)
                .onChange(of: pullRequestState) { _, state in
                    Task { await model.loadPullRequests(state: state) }
                }
                Spacer()
                Button("Refresh") { Task { await model.loadPullRequests(state: pullRequestState) } }
                Button("New Pull Request") { showCreatePullRequest = true }
            }
            .padding(.horizontal, 12)
            if let error = model.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 12)
            }
            if model.pullRequests.isEmpty && !model.isLoading {
                ContentUnavailableView("No pull requests", systemImage: "arrow.triangle.pull")
            } else {
                List(model.pullRequests) { pullRequest in
                    PullRequestRow(pullRequest: pullRequest)
                }
                .listStyle(.inset)
            }
        }
    }

    private var issuesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("State", selection: $issueState) {
                    Text("Open").tag("open")
                    Text("Closed").tag("closed")
                    Text("All").tag("all")
                }
                .frame(width: 150)
                .onChange(of: issueState) { _, state in
                    Task { await model.loadIssues(state: state) }
                }
                Spacer()
                Button("Refresh") { Task { await model.loadIssues(state: issueState) } }
                Button("New Issue") { showCreateIssue = true }
            }
            .padding(.horizontal, 12)
            if model.issues.isEmpty && !model.isLoading {
                ContentUnavailableView("No issues", systemImage: "exclamationmark.bubble")
            } else {
                List(model.issues) { issue in
                    IssueRow(issue: issue)
                }
                .listStyle(.inset)
            }
        }
    }
}

struct PullRequestRow: View {
    let pullRequest: HostingPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(pullRequest.id)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(pullRequest.title ?? "(untitled)")
                    .font(.headline)
                    .lineLimit(1)
                if pullRequest.draft == true { Text("Draft").badgeStyle(.orange) }
                Text(pullRequest.state ?? String(localized: "Unknown"))
                    .badgeStyle(pullRequest.state == "open" ? .green : .secondary)
                Spacer()
                if let urlString = pullRequest.htmlURL, let url = URL(string: urlString) {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }
            HStack(spacing: 12) {
                Text("\(pullRequest.headBranch ?? "?") → \(pullRequest.baseBranch ?? "?")")
                    .font(.system(.caption, design: .monospaced))
                if let author = pullRequest.author?.login { Text(author) }
                if let comments = pullRequest.comments {
                    Text(commentsText(comments))
                }
                if let updated = pullRequest.updatedAt { Text(updated.prefix(10)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct IssueRow: View {
    let issue: HostingIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(issue.id)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(issue.title ?? "(untitled)")
                    .font(.headline)
                    .lineLimit(1)
                Text(issue.state ?? String(localized: "Unknown"))
                    .badgeStyle(issue.state == "open" ? .green : .secondary)
                if issue.isPullRequest { Text("PR").badgeStyle(.purple) }
                Spacer()
                if let urlString = issue.htmlURL, let url = URL(string: urlString) {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }
            HStack(spacing: 12) {
                if let author = issue.author?.login { Text(author) }
                if let comments = issue.comments {
                    Text(commentsText(comments))
                }
                if let updated = issue.updatedAt { Text(updated.prefix(10)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private extension Text {
    func badgeStyle(_ color: Color) -> some View {
        self.font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
    }
}

private func commentsText(_ count: Int) -> String {
    "\(count) \(String(localized: "comments"))"
}

struct PullRequestCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let defaultBase: String
    let onCreate: (String, String, String, String) async -> Bool
    @State private var title = ""
    @State private var details = ""
    @State private var head = ""
    @State private var base: String
    @State private var isSubmitting = false

    init(defaultBase: String, onCreate: @escaping (String, String, String, String) async -> Bool) {
        self.defaultBase = defaultBase
        self.onCreate = onCreate
        self._base = State(initialValue: defaultBase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Pull Request").font(.title2.bold())
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Head branch", text: $head)
                    .textFieldStyle(.roundedBorder)
                TextField("Base branch", text: $base)
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $details)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isSubmitting ? "Loading…" : "Create") {
                    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    isSubmitting = true
                    Task {
                        if await onCreate(title, details, head, base) { dismiss() }
                        isSubmitting = false
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct IssueCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, String) async -> Bool
    @State private var title = ""
    @State private var details = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Issue").font(.title2.bold())
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $details)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isSubmitting ? "Loading…" : "Create") {
                    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    isSubmitting = true
                    Task {
                        if await onCreate(title, details) { dismiss() }
                        isSubmitting = false
                    }
                }
                .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct GitHubSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let repository: HostingRepository
    let client: GitHubClient
    @State private var token = ""
    @State private var status: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub Settings").font(.title2.bold())
            Text(repository.fullName)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Tokens are stored in macOS Keychain and never passed to the git engine.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(status.hasPrefix("Connected") || status.hasPrefix("Saved") ? .green : .red)
            }
            HStack {
                Button("Clear Token", role: .destructive) { clearToken() }
                Spacer()
                Button("Test Connection") { testConnection() }
                    .disabled(isWorking)
                Button("Save Token") { saveToken() }
                    .disabled(isWorking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            do {
                status = try client.storedToken(for: repository) == nil
                    ? String(localized: "No token saved")
                    : String(localized: "Token is configured")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func saveToken() {
        do {
            try client.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: repository)
            token = ""
            status = String(localized: "Saved to Keychain")
        } catch {
            status = error.localizedDescription
        }
    }

    private func clearToken() {
        do {
            try client.clearToken(for: repository)
            token = ""
            status = String(localized: "Token cleared")
        } catch {
            status = error.localizedDescription
        }
    }

    private func testConnection() {
        isWorking = true
        Task {
            do {
                let user = try await client.currentUser(for: repository)
                status = String(localized: "Connected as %@")
                    .replacingOccurrences(of: "%@", with: user.login ?? String(localized: "GitHub user"))
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }
}

struct HostingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let repository: HostingRepository
    let client: any HostingClient
    @State private var token = ""
    @State private var status: String?
    @State private var isWorking = false
    @State private var oauthClientID = UserDefaults.standard.string(forKey: "githubOAuthClientID") ?? ""
    @State private var deviceAuthorization: GitHubDeviceAuthorization?

    init(repository: HostingRepository) {
        self.repository = repository
        self.client = HostingClientFactory.make(for: repository)
    }

    private var providerTitle: String { repository.provider.rawValue.capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(providerTitle) Settings").font(.title2.bold())
            Text(repository.projectPath)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Tokens are stored in macOS Keychain and never passed to the git engine.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField(repository.provider == .bitbucket ? "App password" : "Personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
            if repository.provider == .github {
                Divider()
                Text("GitHub device sign-in")
                    .font(.headline)
                TextField("OAuth client ID", text: $oauthClientID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: oauthClientID) { _, value in
                        UserDefaults.standard.set(value, forKey: "githubOAuthClientID")
                    }
                HStack {
                    Button("Start Device Sign-in") { startGitHubOAuth() }
                        .disabled(isWorking || oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let deviceAuthorization {
                        Text("Code: \(deviceAuthorization.userCode)")
                            .font(.system(.body, design: .monospaced))
                        Button("Open Verification Page") {
                            NSWorkspace.shared.open(deviceAuthorization.verificationURL)
                        }
                    }
                }
            }
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(status.hasPrefix("Connected") || status.hasPrefix("Saved") ? .green : .red)
            }
            HStack {
                Button("Clear Token", role: .destructive) { clearToken() }
                Spacer()
                Button("Test Connection") { testConnection() }
                    .disabled(isWorking)
                Button("Save Token") { saveToken() }
                    .disabled(isWorking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { loadTokenStatus() }
    }

    private func loadTokenStatus() {
        do {
            let stored: String?
            if repository.provider == .github {
                stored = try GitHubClient().storedToken(for: repository)
            } else {
                stored = try KeychainStore.shared.token(for: repository)
            }
            status = stored == nil ? String(localized: "No token saved") : String(localized: "Token is configured")
        } catch {
            status = error.localizedDescription
        }
    }

    private func saveToken() {
        do {
            try KeychainStore.shared.setToken(
                token.trimmingCharacters(in: .whitespacesAndNewlines),
                for: repository
            )
            token = ""
            status = String(localized: "Saved to Keychain")
        } catch {
            status = error.localizedDescription
        }
    }

    private func clearToken() {
        do {
            try KeychainStore.shared.deleteToken(for: repository)
            if repository.provider == .github {
                try? KeychainStore.shared.deleteToken(forOwner: repository.owner)
            }
            token = ""
            status = String(localized: "Token cleared")
        } catch {
            status = error.localizedDescription
        }
    }

    private func testConnection() {
        isWorking = true
        Task {
            do {
                let user = try await client.currentHostingUser(for: repository)
                status = String(localized: "Connected as %@")
                    .replacingOccurrences(of: "%@", with: user.login ?? String(localized: "hosting user"))
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func startGitHubOAuth() {
        guard repository.provider == .github else { return }
        isWorking = true
        Task {
            do {
                let flow = GitHubOAuthFlow(
                    clientID: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let authorization = try await flow.startDeviceAuthorization()
                deviceAuthorization = authorization
                status = "Enter \(authorization.userCode) on GitHub."
                NSWorkspace.shared.open(authorization.verificationURL)
                _ = try await flow.authorizeAndStoreToken(for: repository, authorization: authorization)
                status = String(localized: "Connected and saved to Keychain")
                deviceAuthorization = nil
            } catch {
                status = error.localizedDescription
            }
            isWorking = false
        }
    }
}

struct ReviewCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: HostingRepository
    let commitID: String
    let client: any HostingClient
    @State private var pullRequestNumber = ""
    @State private var path = ""
    @State private var line = ""
    @State private var comment = ""
    @State private var feedback: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Comment").font(.title2.bold())
            Text("Commit \(commitID.prefix(12))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                TextField("Pull request #", text: $pullRequestNumber)
                    .textFieldStyle(.roundedBorder)
                TextField("Line number", text: $line)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("File path", text: $path)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $comment)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                .frame(minHeight: 120)
            if let feedback {
                Text(feedback).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isSubmitting ? "Loading…" : "Submit Comment") { submit() }
                    .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func submit() {
        guard let number = Int(pullRequestNumber.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0,
              let lineNumber = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), lineNumber > 0,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback = String(localized: "Enter a pull request number, file path, line number, and comment.")
            return
        }
        isSubmitting = true
        Task {
            do {
                _ = try await client.postHostingReviewComment(
                    for: repository,
                    pullRequestID: number,
                    body: comment,
                    commitID: commitID,
                    path: path,
                    line: lineNumber
                )
                dismiss()
            } catch {
                feedback = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
