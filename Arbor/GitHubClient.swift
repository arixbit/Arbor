import Foundation

enum GitHubAPIError: Error, LocalizedError, Equatable, Identifiable, Sendable {
    case missingToken(owner: String)
    case unauthorized
    case rateLimited
    case http(status: Int, message: String)
    case invalidResponse
    case transport(message: String)

    var id: String { localizedDescription }

    var isAuthenticationFailure: Bool {
        switch self {
        case .missingToken, .unauthorized: true
        case .http(let status, _): status == 401
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return String(localized: "No GitHub token is configured.")
        case .unauthorized:
            return String(localized: "GitHub authentication failed.")
        case .rateLimited:
            return String(localized: "GitHub API rate limit exceeded.")
        case .http(let status, let message):
            return "GitHub API (\(status): \(message))"
        case .invalidResponse:
            return String(localized: "GitHub returned an invalid response.")
        case .transport(let message):
            return message
        }
    }
}

struct GitHubClient {
    let session: URLSession
    let keychain: KeychainStore
    let rateLimit: HostingRateLimit
    /// Optional override for GitHub Enterprise or a local API proxy.
    let baseURLOverride: URL?

    init(
        session: URLSession = .shared,
        keychain: KeychainStore = .shared,
        baseURL: URL? = nil,
        rateLimit: HostingRateLimit = HostingRateLimit()
    ) {
        self.session = session
        self.keychain = keychain
        self.baseURLOverride = baseURL
        self.rateLimit = rateLimit
    }

    var remainingLimit: Int? { rateLimit.remaining }
    var rateLimitResetDate: Date? { rateLimit.resetDate }

    func storedToken(for repository: HostingRepository) throws -> String? {
        try keychain.token(for: repository) ?? keychain.token(forOwner: repository.owner)
    }

    func saveToken(_ token: String, for repository: HostingRepository) throws {
        try keychain.setToken(token, for: repository)
    }

    func clearToken(for repository: HostingRepository) throws {
        try keychain.deleteToken(for: repository)
        // Remove the pre-v0.10 account too, so an old credential cannot be
        // unexpectedly picked up after the user presses “Clear Token”.
        try keychain.deleteToken(forOwner: repository.owner)
    }

    func currentUser(for repository: HostingRepository) async throws -> GitHubUser {
        try await request(repository: repository, path: ["user"], method: "GET", bodyData: nil)
    }

    func listPullRequests(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [GitHubPullRequest] {
        try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls"],
            query: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )
    }

    func createPullRequest(
        for repository: HostingRepository,
        title: String,
        body: String?,
        head: String,
        base: String
    ) async throws -> GitHubPullRequest {
        try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls"],
            method: "POST",
            bodyData: try JSONEncoder().encode(
                GitHubCreatePullRequestRequest(title: title, body: body, head: head, base: base)
            )
        )
    }

    func listIssues(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [GitHubIssue] {
        try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "issues"],
            query: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )
    }

    func createIssue(
        for repository: HostingRepository,
        title: String,
        body: String?
    ) async throws -> GitHubIssue {
        try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "issues"],
            method: "POST",
            bodyData: try JSONEncoder().encode(GitHubCreateIssueRequest(title: title, body: body))
        )
    }

    func createReviewComment(
        for repository: HostingRepository,
        pullRequestNumber: Int,
        body: String,
        commitID: String,
        path: String,
        line: Int
    ) async throws -> GitHubReviewComment {
        try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(pullRequestNumber), "comments"],
            method: "POST",
            bodyData: try JSONEncoder().encode(
                GitHubCreateReviewCommentRequest(
                    body: body,
                    commitID: commitID,
                    path: path,
                    line: line,
                    side: "RIGHT"
                )
            )
        )
    }

    func loadGitHubChangeRequestDetail(
        for repository: HostingRepository,
        number: Int
    ) async throws -> HostingChangeRequestDetail {
        let pullRequest: GitHubPullRequest = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number)],
            method: "GET",
            bodyData: nil
        )
        let commits: [GitHubPullRequestCommit] = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number), "commits"],
            query: [URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )
        let files: [GitHubPullRequestFile] = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number), "files"],
            query: [URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )
        let comments: [GitHubReviewComment] = (try? await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number), "comments"],
            query: [URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )) ?? []
        let issueComments: [GitHubReviewComment] = (try? await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "issues", String(number), "comments"],
            query: [URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )) ?? []
        let reviews: [GitHubReviewSummary] = (try? await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number), "reviews"],
            query: [URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )) ?? []
        // Issue events contain assignment, label, branch and lifecycle changes
        // that review comments alone cannot represent. The endpoint is
        // optional for older GitHub Enterprise installations, so a failure
        // leaves the detail workspace usable with the data already loaded.
        let events: [GitHubIssueTimelineEvent] = (try? await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "issues", String(number), "events"],
            query: [URLQueryItem(name: "per_page", value: "100")],
            method: "GET",
            bodyData: nil
        )) ?? []
        var timeline = comments.enumerated().map { index, comment in
            HostingTimelineEvent(
                id: "comment-\(comment.apiID ?? 0)-\(index)",
                kind: "comment",
                body: comment.body,
                author: comment.user?.hostingUser,
                createdAt: comment.createdAt,
                path: comment.path,
                line: comment.line ?? comment.originalLine,
                commitID: comment.commitID
            )
        }
        timeline.append(contentsOf: issueComments.enumerated().map { index, comment in
            HostingTimelineEvent(
                id: "issue-comment-\(comment.apiID ?? 0)-\(index)",
                kind: "comment",
                body: comment.body,
                author: comment.user?.hostingUser,
                createdAt: comment.createdAt
            )
        })
        timeline.append(contentsOf: reviews.enumerated().map { index, review in
            HostingTimelineEvent(
                id: "review-\(review.id ?? 0)-\(index)",
                kind: review.state?.lowercased() ?? "review",
                body: review.body,
                author: review.user?.hostingUser,
                createdAt: review.submittedAt
            )
        })
        timeline.append(contentsOf: events.enumerated().map { index, event in
            HostingTimelineEvent(
                id: "event-\(event.id ?? 0)-\(index)",
                kind: event.event ?? "event",
                body: event.body,
                author: event.actor?.hostingUser,
                createdAt: event.createdAt
            )
        })
        timeline.sort { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        let mappedCommits = commits.map {
            HostingChangeRequestCommit(
                id: $0.sha ?? "",
                message: $0.commit?.message,
                author: $0.author?.hostingUser,
                authoredAt: $0.commit?.author?.date
            )
        }.filter { !$0.id.isEmpty }
        let mappedFiles = files.compactMap(\.hostingFile)
        return HostingChangeRequestDetail(
            pullRequest: pullRequest.hostingPullRequest,
            commits: mappedCommits,
            files: mappedFiles,
            timeline: timeline,
            mergeable: pullRequest.mergeable,
            additions: pullRequest.additions,
            deletions: pullRequest.deletions,
            changedFiles: pullRequest.changedFiles,
            capabilities: HostingChangeRequestCapabilities(
                canComment: true,
                canApprove: true,
                canRequestChanges: true,
                canMerge: true,
                canClose: true,
                canRevokeApproval: false,
                mergeMethods: ["merge", "squash", "rebase"]
            ),
            baseRevision: pullRequest.base?.sha,
            startRevision: pullRequest.base?.sha,
            headRevision: pullRequest.head?.sha
        )
    }

    func loadGitHubCommitFiles(
        for repository: HostingRepository,
        commitID: String
    ) async throws -> [HostingChangeRequestFile] {
        let commit: GitHubCommitDetail = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "commits", commitID],
            method: "GET",
            bodyData: nil
        )
        return (commit.files ?? []).compactMap(\.hostingFile)
    }

    func submitGitHubReview(
        for repository: HostingRepository,
        number: Int,
        outcome: HostingReviewOutcome,
        body: String?
    ) async throws {
        let event: String
        switch outcome {
        case .comment: event = "COMMENT"
        case .approve: event = "APPROVE"
        case .requestChanges: event = "REQUEST_CHANGES"
        }
        _ = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number), "reviews"],
            method: "POST",
            bodyData: try JSONEncoder().encode(GitHubSubmitReviewRequest(event: event, body: body))
        ) as GitHubReviewResponse
    }

    func mergeGitHubPullRequest(
        for repository: HostingRepository,
        number: Int,
        method: String
    ) async throws {
        _ = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number), "merge"],
            method: "PUT",
            bodyData: try JSONEncoder().encode(GitHubMergePullRequestRequest(mergeMethod: method))
        ) as GitHubMergeResponse
    }

    func closeGitHubPullRequest(
        for repository: HostingRepository,
        number: Int
    ) async throws {
        _ = try await request(
            repository: repository,
            path: ["repos", repository.owner, repository.name, "pulls", String(number)],
            method: "PATCH",
            bodyData: try JSONEncoder().encode(GitHubClosePullRequestRequest(state: "closed"))
        ) as GitHubPullRequest
    }

    func listGitHubProtectedBranchPatterns(
        for repository: HostingRepository
    ) async throws -> [String] {
        var cursor: String?
        var seenCursors = Set<String>()
        var patterns: [String] = []
        var seenPatterns = Set<String>()

        repeat {
            let graphQLRequest = GitHubGraphQLRequest(
                query: """
                query($repoOwner: String!, $repoName: String!, $cursor: String) {
                  repository(owner: $repoOwner, name: $repoName) {
                    branchProtectionRules(first: 100, after: $cursor) {
                      pageInfo { hasNextPage endCursor }
                      nodes { pattern }
                    }
                  }
                }
                """,
                variables: .init(repoOwner: repository.owner, repoName: repository.name, cursor: cursor)
            )
            let body = try JSONEncoder().encode(graphQLRequest)
            let response: GitHubGraphQLResponse<GitHubProtectionData> = try await request(
                repository: repository,
                path: ["graphql"],
                method: "POST",
                bodyData: body,
                baseURL: graphQLBaseURL(for: repository)
            )

            if let error = response.errors?.first,
               !error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GitHubAPIError.http(status: 422, message: error.message)
            }
            guard let repositoryData = response.data?.repository,
                  let connection = repositoryData.branchProtectionRules else {
                throw GitHubAPIError.invalidResponse
            }

            for pattern in connection.nodes.compactMap(\.pattern) {
                let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, seenPatterns.insert(value).inserted {
                    patterns.append(value)
                }
            }

            guard connection.pageInfo.hasNextPage,
                  let nextCursor = connection.pageInfo.endCursor,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                break
            }
            cursor = nextCursor
        } while true

        return patterns
    }

    private func request<Response: Decodable>(
        repository: HostingRepository,
        path: [String],
        query: [URLQueryItem] = [],
        method: String,
        bodyData: Data?,
        baseURL: URL? = nil
    ) async throws -> Response {
        let token: String
        do {
            guard let stored = try storedToken(for: repository), !stored.isEmpty else {
                throw GitHubAPIError.missingToken(owner: repository.owner)
            }
            token = stored
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.transport(message: error.localizedDescription)
        }

        let requestBaseURL = baseURL ?? baseURLOverride ?? repository.apiBaseURL
        var url = requestBaseURL
        for component in path {
            url.appendPathComponent(component)
        }
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            guard let queryURL = components?.url else {
                throw GitHubAPIError.invalidResponse
            }
            url = queryURL
        }

        do {
            return try await HostingHTTPTransport(session: session, rateLimit: rateLimit).request(
                baseURL: requestBaseURL,
                path: path.joined(separator: "/"),
                query: query,
                method: method,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                ],
                bodyData: bodyData
            )
        } catch let error as HostingAPIError {
            switch error {
            case .unauthorized:
                throw GitHubAPIError.unauthorized
            case .rateLimited:
                throw GitHubAPIError.rateLimited
            case .http(let status, let message):
                throw GitHubAPIError.http(status: status, message: message)
            case .invalidResponse:
                throw GitHubAPIError.invalidResponse
            case .transport(let message):
                throw GitHubAPIError.transport(message: message)
            case .missingToken:
                throw GitHubAPIError.missingToken(owner: repository.owner)
            }
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.transport(message: error.localizedDescription)
        }
    }

    private func graphQLBaseURL(for repository: HostingRepository) -> URL {
        let base = baseURLOverride ?? repository.apiBaseURL
        guard base.path.hasSuffix("/api/v3") else { return base }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = String(base.path.dropLast("/v3".count))
        return components?.url ?? base
    }

    private struct GitHubGraphQLRequest: Encodable {
        let query: String
        let variables: Variables

        struct Variables: Encodable {
            let repoOwner: String
            let repoName: String
            let cursor: String?
        }
    }

    private struct GitHubGraphQLResponse<Data: Decodable>: Decodable {
        let data: Data?
        let errors: [GitHubGraphQLError]?
    }

    private struct GitHubGraphQLError: Decodable {
        let message: String
    }

    private struct GitHubProtectionData: Decodable {
        let repository: GitHubProtectionRepository?
    }

    private struct GitHubProtectionRepository: Decodable {
        let branchProtectionRules: GitHubProtectionConnection?
    }

    private struct GitHubProtectionConnection: Decodable {
        let pageInfo: GitHubProtectionPageInfo
        let nodes: [GitHubProtectionRule]
    }

    private struct GitHubProtectionPageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    private struct GitHubProtectionRule: Decodable {
        let pattern: String?
    }

    private struct GitHubErrorPayload: Decodable {
        let message: String?
    }
}

private struct GitHubPullRequestCommit: Decodable {
    let sha: String?
    let commit: GitHubCommitPayload?
    let author: GitHubUser?
}

private struct GitHubReviewSummary: Decodable {
    let id: Int?
    let body: String?
    let state: String?
    let user: GitHubUser?
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body, state, user
        case submittedAt = "submitted_at"
    }
}

private struct GitHubIssueTimelineEvent: Decodable {
    let id: Int?
    let event: String?
    let body: String?
    let actor: GitHubUser?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, event, body, actor
        case createdAt = "created_at"
    }
}

private struct GitHubCommitPayload: Decodable {
    let message: String?
    let author: GitHubCommitAuthor?
}

private struct GitHubCommitAuthor: Decodable {
    let date: String?
}

private struct GitHubPullRequestFile: Decodable {
    let filename: String?
    let previousFilename: String?
    let status: String?
    let additions: Int?
    let deletions: Int?
    let patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }
}

private extension GitHubPullRequestFile {
    var hostingFile: HostingChangeRequestFile? {
        guard let filename, !filename.isEmpty else { return nil }
        return HostingChangeRequestFile(
            path: filename,
            oldPath: previousFilename,
            status: status,
            additions: additions,
            deletions: deletions,
            patch: patch
        )
    }
}

private struct GitHubCommitDetail: Decodable {
    let files: [GitHubPullRequestFile]?
}

private struct GitHubSubmitReviewRequest: Encodable {
    let event: String
    let body: String?
}

private struct GitHubMergePullRequestRequest: Encodable {
    let mergeMethod: String

    enum CodingKeys: String, CodingKey {
        case mergeMethod = "merge_method"
    }
}

private struct GitHubClosePullRequestRequest: Encodable {
    let state: String
}

private struct GitHubReviewResponse: Decodable {}
private struct GitHubMergeResponse: Decodable {}
