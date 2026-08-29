import Foundation

struct GitLabClient: HostingClient {
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
            let response: [GitLabProtectedBranch] = try await request(
                repository: repository,
                path: projectPath(repository, suffix: "protected_branches"),
                query: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "100"),
                ]
            )
            // GitLab can explicitly allow force pushes on an otherwise protected
            // branch. Only synchronize rules that actually deny history rewrites.
            for branch in response {
                guard branch.allowForcePush != true,
                      let name = branch.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      seenPatterns.insert(name).inserted else { continue }
                patterns.append(name)
            }
            page += 1
            if response.count < 100 { break }
        } while true

        return patterns
    }

    func listHostingPullRequests(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [HostingPullRequest] {
        let response: [GitLabMergeRequest] = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "merge_requests"),
            query: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "per_page", value: "100")]
        )
        return response.map(\.hostingPullRequest)
    }

    func createHostingPullRequest(
        for repository: HostingRepository,
        title: String,
        body: String?,
        head: String,
        base: String
    ) async throws -> HostingPullRequest {
        let payload = GitLabCreateMergeRequest(title: title, description: body, sourceBranch: head, targetBranch: base)
        let response: GitLabMergeRequest = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "merge_requests"),
            method: "POST",
            body: payload
        )
        return response.hostingPullRequest
    }

    func listHostingIssues(
        for repository: HostingRepository,
        state: String = "open"
    ) async throws -> [HostingIssue] {
        let response: [GitLabIssue] = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "issues"),
            query: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "per_page", value: "100")]
        )
        return response.map(\.hostingIssue)
    }

    func createHostingIssue(
        for repository: HostingRepository,
        title: String,
        body: String?
    ) async throws -> HostingIssue {
        let response: GitLabIssue = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "issues"),
            method: "POST",
            body: GitLabCreateIssue(title: title, description: body)
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
        let position: GitLabPosition? = if let line, !path.isEmpty, !commitID.isEmpty {
            GitLabPosition(
                baseSHA: commitID,
                startSHA: commitID,
                headSHA: commitID,
                positionType: "text",
                newPath: path,
                newLine: line
            )
        } else {
            nil
        }
        let response: GitLabDiscussion = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "merge_requests/\(pullRequestID)/discussions"),
            method: "POST",
            body: GitLabCreateDiscussion(body: body, position: position)
        )
        guard let note = response.notes.first else { throw HostingAPIError.invalidResponse }
        return note.hostingComment
    }

    func currentHostingUser(for repository: HostingRepository) async throws -> HostingUser {
        let response: GitLabUser = try await request(repository: repository, path: "user")
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
            body: Optional<GitLabCreateIssue>.none
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
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        return try await HostingHTTPTransport(
            session: session,
            retryDelayOverride: retryDelayOverride
        ).request(
            baseURL: baseURLOverride ?? repository.apiBaseURL,
            path: path,
            query: query,
            method: method,
            headers: ["PRIVATE-TOKEN": token, "Accept": "application/json"],
            bodyData: bodyData
        )
    }

    private func storedToken(for repository: HostingRepository) throws -> String {
        do {
            guard let token = try keychain.token(for: repository), !token.isEmpty else {
                throw HostingAPIError.missingToken(provider: .gitlab, owner: repository.owner)
            }
            return token
        } catch let error as HostingAPIError {
            throw error
        } catch {
            throw HostingAPIError.transport(message: error.localizedDescription)
        }
    }

    private func projectPath(_ repository: HostingRepository, suffix: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = repository.projectPath.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? repository.projectPath
        return "projects/\(encoded)/\(suffix)"
    }
}

// MARK: - GitLab wire models

private struct GitLabProtectedBranch: Decodable {
    let name: String?
    let allowForcePush: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case allowForcePush = "allow_force_push"
    }
}

private struct GitLabUser: Decodable {
    let username: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case username
        case avatarURL = "avatar_url"
    }

    var hostingUser: HostingUser { HostingUser(login: username, avatarURL: avatarURL) }
}

private struct GitLabMergeRequest: Decodable {
    let id: Int?
    let iid: Int?
    let title: String?
    let description: String?
    let state: String?
    let draft: Bool?
    let workInProgress: Bool?
    let webURL: String?
    let author: GitLabUser?
    let sourceBranch: String?
    let targetBranch: String?
    let updatedAt: String?
    let userNotesCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, iid, title, description, state, draft, author
        case workInProgress = "work_in_progress"
        case webURL = "web_url"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case updatedAt = "updated_at"
        case userNotesCount = "user_notes_count"
    }

    var hostingPullRequest: HostingPullRequest {
        HostingPullRequest(
            id: iid ?? id ?? 0,
            title: title,
            body: description,
            state: state,
            draft: draft ?? workInProgress,
            htmlURL: webURL,
            author: author?.hostingUser,
            headBranch: sourceBranch,
            baseBranch: targetBranch,
            updatedAt: updatedAt,
            comments: userNotesCount
        )
    }
}

private struct GitLabIssue: Decodable {
    let id: Int?
    let iid: Int?
    let title: String?
    let description: String?
    let state: String?
    let webURL: String?
    let author: GitLabUser?
    let userNotesCount: Int?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, iid, title, description, state, author
        case webURL = "web_url"
        case userNotesCount = "user_notes_count"
        case updatedAt = "updated_at"
    }

    var hostingIssue: HostingIssue {
        HostingIssue(
            id: iid ?? id ?? 0,
            title: title,
            body: description,
            state: state,
            htmlURL: webURL,
            author: author?.hostingUser,
            comments: userNotesCount,
            updatedAt: updatedAt,
            isPullRequest: false
        )
    }
}

private struct GitLabNote: Decodable {
    let id: Int?
    let body: String?
    let author: GitLabUser?
    let noteableWebURL: String?
    let position: GitLabNotePosition?

    enum CodingKeys: String, CodingKey {
        case id, body, author, position
        case noteableWebURL = "noteable_web_url"
    }

    var hostingComment: HostingComment {
        HostingComment(
            id: id ?? 0,
            body: body,
            path: position?.newPath,
            line: position?.newLine,
            commitID: position?.headSHA,
            author: author?.hostingUser,
            htmlURL: noteableWebURL
        )
    }
}

private struct GitLabNotePosition: Decodable {
    let headSHA: String?
    let newPath: String?
    let newLine: Int?

    enum CodingKeys: String, CodingKey {
        case headSHA = "head_sha"
        case newPath = "new_path"
        case newLine = "new_line"
    }
}

private struct GitLabDiscussion: Decodable {
    let notes: [GitLabNote]
}

private struct GitLabPosition: Codable {
    let baseSHA: String
    let startSHA: String
    let headSHA: String
    let positionType: String
    let newPath: String
    let newLine: Int

    enum CodingKeys: String, CodingKey {
        case baseSHA = "base_sha"
        case startSHA = "start_sha"
        case headSHA = "head_sha"
        case positionType = "position_type"
        case newPath = "new_path"
        case newLine = "new_line"
    }
}

private struct GitLabCreateMergeRequest: Encodable {
    let title: String
    let description: String?
    let sourceBranch: String
    let targetBranch: String

    enum CodingKeys: String, CodingKey {
        case title, description
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
    }
}

private struct GitLabCreateIssue: Encodable {
    let title: String
    let description: String?
}

private struct GitLabCreateDiscussion: Encodable {
    let body: String
    let position: GitLabPosition?
}
