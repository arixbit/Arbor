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

    func hostingPullRequestDetail(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws -> HostingChangeRequestDetail

    func hostingPullRequestFiles(
        for repository: HostingRepository,
        pullRequestID: Int,
        commitID: String
    ) async throws -> [HostingChangeRequestFile]

    func submitHostingReview(
        for repository: HostingRepository,
        pullRequestID: Int,
        outcome: HostingReviewOutcome,
        body: String?
    ) async throws

    func mergeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int,
        method: String
    ) async throws

    func closeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws

    func revokeHostingApproval(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws
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

    func hostingPullRequestDetail(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws -> HostingChangeRequestDetail {
        throw HostingAPIError.http(status: 501, message: "Pull request details are not supported by this provider")
    }

    func hostingPullRequestFiles(
        for repository: HostingRepository,
        pullRequestID: Int,
        commitID: String
    ) async throws -> [HostingChangeRequestFile] {
        try await hostingPullRequestDetail(
            for: repository,
            pullRequestID: pullRequestID
        ).files
    }

    func submitHostingReview(
        for repository: HostingRepository,
        pullRequestID: Int,
        outcome: HostingReviewOutcome,
        body: String?
    ) async throws {
        throw HostingAPIError.http(status: 501, message: "Pull request reviews are not supported by this provider")
    }

    func mergeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int,
        method: String
    ) async throws {
        throw HostingAPIError.http(status: 501, message: "Pull request merge is not supported by this provider")
    }

    func closeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws {
        throw HostingAPIError.http(status: 501, message: "Pull request close is not supported by this provider")
    }

    func revokeHostingApproval(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws {
        throw HostingAPIError.http(status: 501, message: "Approval revoke is not supported by this provider")
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

    func hostingPullRequestDetail(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws -> HostingChangeRequestDetail {
        try await loadGitHubChangeRequestDetail(for: repository, number: pullRequestID)
    }

    func hostingPullRequestFiles(
        for repository: HostingRepository,
        pullRequestID: Int,
        commitID: String
    ) async throws -> [HostingChangeRequestFile] {
        try await loadGitHubCommitFiles(for: repository, commitID: commitID)
    }

    func submitHostingReview(
        for repository: HostingRepository,
        pullRequestID: Int,
        outcome: HostingReviewOutcome,
        body: String?
    ) async throws {
        try await submitGitHubReview(
            for: repository,
            number: pullRequestID,
            outcome: outcome,
            body: body
        )
    }

    func mergeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int,
        method: String
    ) async throws {
        try await mergeGitHubPullRequest(for: repository, number: pullRequestID, method: method)
    }

    func closeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws {
        try await closeGitHubPullRequest(for: repository, number: pullRequestID)
    }
}

extension GitLabClient {
    func hostingPullRequestDetail(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws -> HostingChangeRequestDetail {
        try await loadGitLabChangeRequestDetail(for: repository, iid: pullRequestID)
    }

    func hostingPullRequestFiles(
        for repository: HostingRepository,
        pullRequestID: Int,
        commitID: String
    ) async throws -> [HostingChangeRequestFile] {
        try await loadGitLabCommitFiles(for: repository, commitID: commitID)
    }

    func submitHostingReview(
        for repository: HostingRepository,
        pullRequestID: Int,
        outcome: HostingReviewOutcome,
        body: String?
    ) async throws {
        try await submitGitLabReview(
            for: repository,
            iid: pullRequestID,
            outcome: outcome,
            body: body
        )
    }

    func mergeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int,
        method: String
    ) async throws {
        try await mergeGitLabMergeRequest(for: repository, iid: pullRequestID, method: method)
    }

    func closeHostingPullRequest(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws {
        try await closeGitLabMergeRequest(for: repository, iid: pullRequestID)
    }

    func revokeHostingApproval(
        for repository: HostingRepository,
        pullRequestID: Int
    ) async throws {
        try await revokeGitLabApproval(for: repository, iid: pullRequestID)
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
