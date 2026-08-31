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

    func loadGitLabChangeRequestDetail(
        for repository: HostingRepository,
        iid: Int
    ) async throws -> HostingChangeRequestDetail {
        let requestPath = projectPath(repository, suffix: "merge_requests/\(iid)")
        let mergeRequest: GitLabMergeRequest = try await request(
            repository: repository,
            path: requestPath
        )
        let commits: [GitLabCommit] = (try? await request(
            repository: repository,
            path: "\(requestPath)/commits",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )) ?? []
        let changes: GitLabMergeRequestChanges = (try? await request(
            repository: repository,
            path: "\(requestPath)/changes"
        )) ?? GitLabMergeRequestChanges(changes: [])
        let discussions: [GitLabDiscussion] = (try? await request(
            repository: repository,
            path: "\(requestPath)/discussions",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )) ?? []
        let approvalStatus: GitLabApprovalStatus? = try? await request(
            repository: repository,
            path: "\(requestPath)/approvals"
        )
        let approved = approvalStatus?.approved == true
        let timeline = discussions.flatMap { discussion in
            discussion.notes.enumerated().map { index, note in
                HostingTimelineEvent(
                    id: "discussion-\(note.id ?? 0)-\(index)",
                    kind: "discussion",
                    body: note.body,
                    author: note.author?.hostingUser,
                    createdAt: note.createdAt,
                    path: note.position?.newPath,
                    line: note.position?.newLine,
                    commitID: note.position?.headSHA
                )
            }
        }
        let mappedCommits = commits.compactMap { commit -> HostingChangeRequestCommit? in
            guard let id = commit.id, !id.isEmpty else { return nil }
            return HostingChangeRequestCommit(
                id: id,
                message: commit.title,
                author: commit.authorName.map { HostingUser(login: $0, avatarURL: nil) },
                authoredAt: commit.createdAt
            )
        }
        let mappedFiles = changes.changes.compactMap(\.hostingFile)
        return HostingChangeRequestDetail(
            pullRequest: mergeRequest.hostingPullRequest,
            commits: mappedCommits,
            files: mappedFiles,
            timeline: timeline,
            mergeable: mergeRequest.mergeStatus == "can_be_merged",
            additions: nil,
            deletions: nil,
            changedFiles: mappedFiles.count,
            capabilities: HostingChangeRequestCapabilities(
                canComment: true,
                canApprove: !approved,
                canRequestChanges: false,
                canMerge: true,
                canClose: true,
                canRevokeApproval: approved,
                mergeMethods: ["merge", "squash"]
            ),
            baseRevision: mergeRequest.diffRefs?.baseSHA,
            startRevision: mergeRequest.diffRefs?.startSHA,
            headRevision: mergeRequest.diffRefs?.headSHA
        )
    }

    func loadGitLabCommitFiles(
        for repository: HostingRepository,
        commitID: String
    ) async throws -> [HostingChangeRequestFile] {
        let changes: [GitLabChange] = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "repository/commits/\(commitID)/diff"),
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        return changes.compactMap(\.hostingFile)
    }

    func submitGitLabReview(
        for repository: HostingRepository,
        iid: Int,
        outcome: HostingReviewOutcome,
        body: String?
    ) async throws {
        switch outcome {
        case .comment:
            let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw HostingAPIError.invalidResponse }
            _ = try await request(
                repository: repository,
                path: projectPath(repository, suffix: "merge_requests/\(iid)/notes"),
                method: "POST",
                body: GitLabCreateNote(body: text)
            ) as GitLabNote
        case .approve:
            _ = try await request(
                repository: repository,
                path: projectPath(repository, suffix: "merge_requests/\(iid)/approve"),
                method: "POST"
            ) as GitLabApprovalResponse
        case .requestChanges:
            throw HostingAPIError.http(status: 501, message: "GitLab does not expose Request Changes for this client")
        }
    }

    func mergeGitLabMergeRequest(
        for repository: HostingRepository,
        iid: Int,
        method: String
    ) async throws {
        guard method == "merge" || method == "squash" else {
            throw HostingAPIError.http(status: 501, message: "GitLab merge method is unavailable")
        }
        _ = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "merge_requests/\(iid)/merge"),
            method: "PUT",
            body: GitLabMergeAction(squash: method == "squash")
        ) as GitLabMergeRequest
    }

    func closeGitLabMergeRequest(
        for repository: HostingRepository,
        iid: Int
    ) async throws {
        _ = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "merge_requests/\(iid)"),
            method: "PUT",
            body: GitLabStateAction(stateEvent: "close")
        ) as GitLabMergeRequest
    }

    func revokeGitLabApproval(
        for repository: HostingRepository,
        iid: Int
    ) async throws {
        _ = try await request(
            repository: repository,
            path: projectPath(repository, suffix: "merge_requests/\(iid)/unapprove"),
            method: "POST"
        ) as GitLabApprovalResponse
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
    let mergeStatus: String?
    let assignees: [GitLabUser]?
    let reviewers: [GitLabUser]?
    let labels: [String]?
    let diffRefs: GitLabDiffRefs?

    enum CodingKeys: String, CodingKey {
        case id, iid, title, description, state, draft, author
        case workInProgress = "work_in_progress"
        case webURL = "web_url"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case updatedAt = "updated_at"
        case userNotesCount = "user_notes_count"
        case mergeStatus = "merge_status"
        case assignees, reviewers, labels
        case diffRefs = "diff_refs"
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
            comments: userNotesCount,
            assignees: assignees?.map(\.hostingUser),
            reviewers: reviewers?.map(\.hostingUser),
            labels: labels
        )
    }
}

private struct GitLabDiffRefs: Decodable {
    let baseSHA: String?
    let startSHA: String?
    let headSHA: String?

    enum CodingKeys: String, CodingKey {
        case baseSHA = "base_sha"
        case startSHA = "start_sha"
        case headSHA = "head_sha"
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
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body, author, position
        case noteableWebURL = "noteable_web_url"
        case createdAt = "created_at"
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

private struct GitLabCommit: Decodable {
    let id: String?
    let title: String?
    let authorName: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case authorName = "author_name"
        case createdAt = "created_at"
    }
}

private struct GitLabMergeRequestChanges: Decodable {
    let changes: [GitLabChange]
}

private struct GitLabChange: Decodable {
    let oldPath: String?
    let newPath: String?
    let newFile: Bool?
    let deletedFile: Bool?
    let diff: String?

    enum CodingKeys: String, CodingKey {
        case diff
        case oldPath = "old_path"
        case newPath = "new_path"
        case newFile = "new_file"
        case deletedFile = "deleted_file"
    }
}

private extension GitLabChange {
    var hostingFile: HostingChangeRequestFile? {
        guard let path = newPath ?? oldPath, !path.isEmpty else { return nil }
        return HostingChangeRequestFile(
            path: path,
            oldPath: oldPath,
            status: deletedFile == true ? "deleted" : (newFile == true ? "added" : "modified"),
            additions: nil,
            deletions: nil,
            patch: diff
        )
    }
}

private struct GitLabCreateNote: Encodable {
    let body: String
}

private struct GitLabMergeAction: Encodable {
    let squash: Bool
}

private struct GitLabStateAction: Encodable {
    let stateEvent: String

    enum CodingKeys: String, CodingKey {
        case stateEvent = "state_event"
    }
}

private struct GitLabApprovalResponse: Decodable {}

private struct GitLabApprovalStatus: Decodable {
    let approved: Bool?
}
