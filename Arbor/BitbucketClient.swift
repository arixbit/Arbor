import Foundation

struct BitbucketClient: HostingClient {
    let session: URLSession
    let keychain: KeychainStore
    let baseURLOverride: URL?
    let retryDelayOverride: TimeInterval?

    init(
        session: URLSession = .shared,
        keychain: KeychainStore = .shared,
        baseURL: URL? = nil,
        retryDelayOverride: TimeInterval? = nil
    ) {
        self.session = session
        self.keychain = keychain
        self.baseURLOverride = baseURL
        self.retryDelayOverride = retryDelayOverride
    }

    func listProtectedBranchPatterns(
        for repository: HostingRepository
    ) async throws -> [String] {
        var page = 1
        var patterns: [String] = []
        var seenPatterns = Set<String>()

        repeat {
            let response: BitbucketPage<BitbucketBranchRestriction> = try await request(
                repository: repository,
                path: repositoryPath(repository, suffix: "branch-restrictions"),
                query: [
                    URLQueryItem(name: "kind", value: "force"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "pagelen", value: "100"),
                ]
            )
            // A force restriction is the Bitbucket Cloud rule that prevents
            // history rewrites. Branching-model restrictions without a concrete
            // glob are intentionally ignored because the API does not return the
            // repository's resolved branch name in this response.
            for restriction in response.values {
                guard restriction.kind == "force",
                      restriction.branchMatchKind == "glob",
                      let pattern = restriction.pattern?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !pattern.isEmpty,
                      seenPatterns.insert(pattern).inserted else { continue }
                patterns.append(pattern)
            }
            page += 1
            if response.values.count < 100 { break }
        } while true

        return patterns
    }

    func listHostingPullRequests(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [HostingPullRequest] {
        let response: BitbucketPage<BitbucketPullRequest> = try await request(
            repository: repository,
            path: repositoryPath(repository, suffix: "pullrequests"),
            query: state.lowercased() == "all" ? [] : [URLQueryItem(name: "state", value: state.uppercased())]
        )
        return response.values.map(\.hostingPullRequest)
    }

    func createHostingPullRequest(
        for repository: HostingRepository,
        title: String,
        body: String?,
        head: String,
        base: String
    ) async throws -> HostingPullRequest {
        let payload = BitbucketCreatePullRequest(
            title: title,
            description: body,
            source: BitbucketBranchRef(branch: BitbucketBranch(name: head)),
            destination: BitbucketBranchRef(branch: BitbucketBranch(name: base))
        )
        let response: BitbucketPullRequest = try await request(
            repository: repository,
            path: repositoryPath(repository, suffix: "pullrequests"),
            method: "POST",
            body: payload
        )
        return response.hostingPullRequest
    }

    func listHostingIssues(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [HostingIssue] {
        let response: BitbucketPage<BitbucketIssue> = try await request(
            repository: repository,
            path: repositoryPath(repository, suffix: "issues"),
            query: state.lowercased() == "all" ? [] : [URLQueryItem(name: "state", value: state.uppercased())]
        )
        return response.values.map(\.hostingIssue)
    }

    func createHostingIssue(
        for repository: HostingRepository,
        title: String,
        body: String?
    ) async throws -> HostingIssue {
        let response: BitbucketIssue = try await request(
            repository: repository,
            path: repositoryPath(repository, suffix: "issues"),
            method: "POST",
            body: BitbucketCreateIssue(title: title, content: BitbucketContent(raw: body ?? ""))
        )
        return response.hostingIssue
    }

    func postHostingReviewComment(
        for repository: HostingRepository,
        pullRequestID: Int,
        body: String,
        commitID: String,
        path: String,
        line: Int?
    ) async throws -> HostingComment {
        // Bitbucket's REST shape differs from GitHub/GitLab. v0.10 posts a
        // regular PR comment and intentionally drops file/line metadata.
        let response: BitbucketComment = try await request(
            repository: repository,
            path: repositoryPath(repository, suffix: "pullrequests/\(pullRequestID)/comments"),
            method: "POST",
            body: BitbucketCreateComment(content: BitbucketContent(raw: body))
        )
        return response.hostingComment
    }

    func currentHostingUser(for repository: HostingRepository) async throws -> HostingUser {
        let response: BitbucketUser = try await request(repository: repository, path: "user")
        return response.hostingUser
    }

    private func request<Response: Decodable>(
        repository: HostingRepository,
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET"
    ) async throws -> Response {
        try await request(
            repository: repository,
            path: path,
            query: query,
            method: method,
            body: Optional<BitbucketCreateIssue>.none
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        repository: HostingRepository,
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Body? = nil
    ) async throws -> Response {
        let token = try storedToken(for: repository)
        let credentials = Data("\(repository.owner):\(token)".utf8).base64EncodedString()
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        return try await HostingHTTPTransport(
            session: session,
            retryDelayOverride: retryDelayOverride
        ).request(
            baseURL: baseURLOverride ?? repository.apiBaseURL,
            path: path,
            query: query,
            method: method,
            headers: ["Authorization": "Basic \(credentials)", "Accept": "application/json"],
            bodyData: bodyData
        )
    }

    private func storedToken(for repository: HostingRepository) throws -> String {
        do {
            guard let token = try keychain.token(for: repository), !token.isEmpty else {
                throw HostingAPIError.missingToken(provider: .bitbucket, owner: repository.owner)
            }
            return token
        } catch let error as HostingAPIError {
            throw error
        } catch {
            throw HostingAPIError.transport(message: error.localizedDescription)
        }
    }

    private func repositoryPath(_ repository: HostingRepository, suffix: String) -> String {
        "repositories/\(repository.owner)/\(repository.name)/\(suffix)"
    }
}

// MARK: - Bitbucket wire models

private struct BitbucketPage<Value: Decodable>: Decodable {
    let values: [Value]
}

private struct BitbucketBranchRestriction: Decodable {
    let kind: String?
    let branchMatchKind: String?
    let pattern: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case branchMatchKind = "branch_match_kind"
        case pattern
    }
}

private struct BitbucketUser: Decodable {
    let nickname: String?
    let username: String?
    let displayName: String?
    let links: BitbucketLinks?

    enum CodingKeys: String, CodingKey {
        case nickname, username, links
        case displayName = "display_name"
    }

    var hostingUser: HostingUser {
        HostingUser(login: nickname ?? username ?? displayName, avatarURL: links?.avatar?.href)
    }
}

private struct BitbucketLinks: Decodable {
    let html: BitbucketLink?
    let avatar: BitbucketLink?
}

private struct BitbucketLink: Decodable {
    let href: String?
}

private struct BitbucketBranch: Codable {
    let name: String
}

private struct BitbucketBranchRef: Codable {
    let branch: BitbucketBranch
}

private struct BitbucketContent: Codable {
    let raw: String
}

private struct BitbucketPullRequest: Decodable {
    let id: Int?
    let title: String?
    let description: String?
    let state: String?
    let draft: Bool?
    let links: BitbucketLinks?
    let author: BitbucketUser?
    let source: BitbucketBranchRef?
    let destination: BitbucketBranchRef?
    let updatedOn: String?
    let commentCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, description, state, draft, links, author, source, destination
        case updatedOn = "updated_on"
        case commentCount = "comment_count"
    }

    var hostingPullRequest: HostingPullRequest {
        HostingPullRequest(
            id: id ?? 0,
            title: title,
            body: description,
            state: state,
            draft: draft,
            htmlURL: links?.html?.href,
            author: author?.hostingUser,
            headBranch: source?.branch.name,
            baseBranch: destination?.branch.name,
            updatedAt: updatedOn,
            comments: commentCount
        )
    }
}

private struct BitbucketIssue: Decodable {
    let id: Int?
    let title: String?
    let content: BitbucketContent?
    let state: String?
    let links: BitbucketLinks?
    let reporter: BitbucketUser?
    let commentCount: Int?
    let updatedOn: String?
    let pullRequest: BitbucketLink?

    enum CodingKeys: String, CodingKey {
        case id, title, content, state, links, reporter
        case commentCount = "comment_count"
        case updatedOn = "updated_on"
        case pullRequest = "pullrequest"
    }

    var hostingIssue: HostingIssue {
        HostingIssue(
            id: id ?? 0,
            title: title,
            body: content?.raw,
            state: state,
            htmlURL: links?.html?.href,
            author: reporter?.hostingUser,
            comments: commentCount,
            updatedAt: updatedOn,
            isPullRequest: pullRequest != nil
        )
    }
}

private struct BitbucketComment: Decodable {
    let id: Int?
    let content: BitbucketContent?
    let user: BitbucketUser?
    let links: BitbucketLinks?

    var hostingComment: HostingComment {
        HostingComment(
            id: id ?? 0,
            body: content?.raw,
            path: nil,
            line: nil,
            commitID: nil,
            author: user?.hostingUser,
            htmlURL: links?.html?.href
        )
    }
}

private struct BitbucketCreatePullRequest: Encodable {
    let title: String
    let description: String?
    let source: BitbucketBranchRef
    let destination: BitbucketBranchRef
}

private struct BitbucketCreateIssue: Encodable {
    let title: String
    let content: BitbucketContent
}

private struct BitbucketCreateComment: Encodable {
    let content: BitbucketContent
}
