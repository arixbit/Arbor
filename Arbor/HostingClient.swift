import Foundation

protocol HostingClient {
    func listProtectedBranchPatterns(
        for repository: HostingRepository
    ) async throws -> [String]

    func listHostingPullRequests(
        for repository: HostingRepository,
        state: String
    ) async throws -> [HostingPullRequest]

    func createHostingPullRequest(
        for repository: HostingRepository,
        title: String,
        body: String?,
        head: String,
        base: String
    ) async throws -> HostingPullRequest

    func listHostingIssues(
        for repository: HostingRepository,
        state: String
    ) async throws -> [HostingIssue]

    func createHostingIssue(
        for repository: HostingRepository,
        title: String,
        body: String?
    ) async throws -> HostingIssue

    func postHostingReviewComment(
        for repository: HostingRepository,
        pullRequestID: Int,
        body: String,
        commitID: String,
        path: String,
        line: Int?
    ) async throws -> HostingComment

    func currentHostingUser(for repository: HostingRepository) async throws -> HostingUser
}

extension HostingClient {
    /// Branch protection synchronization is provider-specific. GitHub has a
    /// first-class implementation; other hosting clients keep the capability
    /// optional instead of pretending their APIs expose the same semantics.
    func listProtectedBranchPatterns(
        for repository: HostingRepository
    ) async throws -> [String] {
        []
    }
}

extension GitHubClient: HostingClient {
    func listProtectedBranchPatterns(
        for repository: HostingRepository
    ) async throws -> [String] {
        try await listGitHubProtectedBranchPatterns(for: repository)
    }

    func listHostingPullRequests(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [HostingPullRequest] {
        try await listPullRequests(for: repository, state: state).map(\.hostingPullRequest)
    }

    func createHostingPullRequest(
        for repository: HostingRepository,
        title: String,
        body: String?,
        head: String,
        base: String
    ) async throws -> HostingPullRequest {
        try await createPullRequest(for: repository, title: title, body: body, head: head, base: base)
            .hostingPullRequest
    }

    func listHostingIssues(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [HostingIssue] {
        try await listIssues(for: repository, state: state).map(\.hostingIssue)
    }

    func createHostingIssue(
        for repository: HostingRepository,
        title: String,
        body: String?
    ) async throws -> HostingIssue {
        try await createIssue(for: repository, title: title, body: body).hostingIssue
    }

    func postHostingReviewComment(
        for repository: HostingRepository,
        pullRequestID: Int,
        body: String,
        commitID: String,
        path: String,
        line: Int?
    ) async throws -> HostingComment {
        guard let line else { throw HostingAPIError.invalidResponse }
        return try await createReviewComment(
            for: repository,
            pullRequestNumber: pullRequestID,
            body: body,
            commitID: commitID,
            path: path,
            line: line
        ).hostingComment
    }

    func currentHostingUser(for repository: HostingRepository) async throws -> HostingUser {
        try await currentUser(for: repository).hostingUser
    }
}

enum HostingClientFactory {
    static func make(
        for repository: HostingRepository,
        session: URLSession = .shared,
        keychain: KeychainStore = .shared,
        baseURLOverride: URL? = nil,
        retryDelayOverride: TimeInterval? = nil
    ) -> any HostingClient {
        switch repository.provider {
        case .github:
            return GitHubClient(session: session, keychain: keychain, baseURL: baseURLOverride)
        case .gitlab:
            return GitLabClient(
                session: session,
                keychain: keychain,
                baseURL: baseURLOverride,
                retryDelayOverride: retryDelayOverride
            )
        case .bitbucket:
            return BitbucketClient(
                session: session,
                keychain: keychain,
                baseURL: baseURLOverride,
                retryDelayOverride: retryDelayOverride
            )
        }
    }
}
