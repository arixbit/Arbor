import Foundation

struct GitHubUser: Codable, Equatable, Sendable {
    let login: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct GitHubBranchRef: Codable, Equatable, Sendable {
    let ref: String?
    let sha: String?
    let label: String?
    let repo: GitHubRepositorySummary?
}

struct GitHubRepositorySummary: Codable, Equatable, Sendable {
    let fullName: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case htmlURL = "html_url"
    }
}

struct GitHubLabel: Codable, Equatable, Sendable {
    let name: String?
}

struct GitHubPullRequest: Codable, Equatable, Identifiable, Sendable {
    let apiID: Int?
    let number: Int?
    let title: String?
    let body: String?
    let state: String?
    let draft: Bool?
    let htmlURL: String?
    let user: GitHubUser?
    let head: GitHubBranchRef?
    let base: GitHubBranchRef?
    let updatedAt: String?
    let comments: Int?
    let mergeable: Bool?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let assignees: [GitHubUser]?
    let requestedReviewers: [GitHubUser]?
    let labels: [GitHubLabel]?

    var id: Int { number ?? 0 }

    enum CodingKeys: String, CodingKey {
        case apiID = "id"
        case number, title, body, state, draft, user, head, base, comments, mergeable, additions, deletions, assignees, labels
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case changedFiles = "changed_files"
        case requestedReviewers = "requested_reviewers"
    }
}

struct GitHubIssue: Codable, Equatable, Identifiable, Sendable {
    let apiID: Int?
    let number: Int?
    let title: String?
    let body: String?
    let state: String?
    let htmlURL: String?
    let user: GitHubUser?
    let comments: Int?
    let updatedAt: String?
    let pullRequest: GitHubRepositorySummary?

    var id: Int { number ?? 0 }

    enum CodingKeys: String, CodingKey {
        case apiID = "id"
        case number, title, body, state, user, comments
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }
}

struct GitHubReviewComment: Codable, Equatable, Identifiable, Sendable {
    let apiID: Int?
    let body: String?
    let path: String?
    let line: Int?
    let originalLine: Int?
    let side: String?
    let commitID: String?
    let user: GitHubUser?
    let htmlURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case apiID = "id"
        case body, path, line, side, user
        case originalLine = "original_line"
        case commitID = "commit_id"
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }

    var id: Int { apiID ?? 0 }
}

struct GitHubCreatePullRequestRequest: Encodable, Sendable {
    let title: String
    let body: String?
    let head: String
    let base: String
}

struct GitHubCreateIssueRequest: Encodable, Sendable {
    let title: String
    let body: String?
}

struct GitHubCreateReviewCommentRequest: Encodable, Sendable {
    let body: String
    let commitID: String
    let path: String
    let line: Int
    let side: String

    enum CodingKeys: String, CodingKey {
        case body, path, line, side
        case commitID = "commit_id"
    }
}

// MARK: Provider-neutral hosting models

struct HostingUser: Codable, Equatable, Sendable {
    let login: String?
    let avatarURL: String?
}

struct HostingPullRequest: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let title: String?
    let body: String?
    let state: String?
    let draft: Bool?
    let htmlURL: String?
    let author: HostingUser?
    let headBranch: String?
    let baseBranch: String?
    let updatedAt: String?
    let comments: Int?
    var assignees: [HostingUser]? = nil
    var reviewers: [HostingUser]? = nil
    var labels: [String]? = nil

    init(
        id: Int,
        title: String?,
        body: String?,
        state: String?,
        draft: Bool?,
        htmlURL: String?,
        author: HostingUser?,
        headBranch: String?,
        baseBranch: String?,
        updatedAt: String?,
        comments: Int?,
        assignees: [HostingUser]? = nil,
        reviewers: [HostingUser]? = nil,
        labels: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.state = state
        self.draft = draft
        self.htmlURL = htmlURL
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.updatedAt = updatedAt
        self.comments = comments
        self.assignees = assignees
        self.reviewers = reviewers
        self.labels = labels
    }
}

struct HostingIssue: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let title: String?
    let body: String?
    let state: String?
    let htmlURL: String?
    let author: HostingUser?
    let comments: Int?
    let updatedAt: String?
    let isPullRequest: Bool
}

struct HostingComment: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let body: String?
    var path: String? = nil
    var line: Int? = nil
    var commitID: String? = nil
    let author: HostingUser?
    let htmlURL: String?
}

enum HostingReviewOutcome: String, Codable, CaseIterable, Identifiable, Sendable {
    case comment
    case approve
    case requestChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request Changes"
        }
    }
}

struct HostingChangeRequestCapabilities: Codable, Equatable, Sendable {
    let canComment: Bool
    let canApprove: Bool
    let canRequestChanges: Bool
    let canMerge: Bool
    let canClose: Bool
    let canRevokeApproval: Bool
    let mergeMethods: [String]
}

struct HostingChangeRequestCommit: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let message: String?
    let author: HostingUser?
    let authoredAt: String?
}

struct HostingChangeRequestFile: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let oldPath: String?
    let status: String?
    let additions: Int?
    let deletions: Int?
    let patch: String?

    var id: String { path }
}

struct HostingTimelineEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let body: String?
    let author: HostingUser?
    let createdAt: String?
    var path: String?
    var line: Int?
    var commitID: String?

    init(
        id: String,
        kind: String,
        body: String?,
        author: HostingUser?,
        createdAt: String?,
        path: String? = nil,
        line: Int? = nil,
        commitID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.path = path
        self.line = line
        self.commitID = commitID
    }
}

struct HostingChangeRequestDetail: Codable, Equatable, Sendable {
    let pullRequest: HostingPullRequest
    let commits: [HostingChangeRequestCommit]
    let files: [HostingChangeRequestFile]
    let timeline: [HostingTimelineEvent]
    let mergeable: Bool?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let capabilities: HostingChangeRequestCapabilities
    var baseRevision: String? = nil
    var startRevision: String? = nil
    var headRevision: String? = nil

    init(
        pullRequest: HostingPullRequest,
        commits: [HostingChangeRequestCommit],
        files: [HostingChangeRequestFile],
        timeline: [HostingTimelineEvent],
        mergeable: Bool?,
        additions: Int?,
        deletions: Int?,
        changedFiles: Int?,
        capabilities: HostingChangeRequestCapabilities,
        baseRevision: String? = nil,
        startRevision: String? = nil,
        headRevision: String? = nil
    ) {
        self.pullRequest = pullRequest
        self.commits = commits
        self.files = files
        self.timeline = timeline
        self.mergeable = mergeable
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.capabilities = capabilities
        self.baseRevision = baseRevision
        self.startRevision = startRevision
        self.headRevision = headRevision
    }
}

extension GitHubUser {
    var hostingUser: HostingUser {
        HostingUser(login: login, avatarURL: avatarURL)
    }
}

extension GitHubPullRequest {
    var hostingPullRequest: HostingPullRequest {
        HostingPullRequest(
            id: number ?? apiID ?? 0,
            title: title,
            body: body,
            state: state,
            draft: draft,
            htmlURL: htmlURL,
            author: user?.hostingUser,
            headBranch: head?.ref,
            baseBranch: base?.ref,
            updatedAt: updatedAt,
            comments: comments,
            assignees: assignees?.map(\.hostingUser),
            reviewers: requestedReviewers?.map(\.hostingUser),
            labels: labels?.compactMap(\.name)
        )
    }
}

extension GitHubIssue {
    var hostingIssue: HostingIssue {
        HostingIssue(
            id: number ?? apiID ?? 0,
            title: title,
            body: body,
            state: state,
            htmlURL: htmlURL,
            author: user?.hostingUser,
            comments: comments,
            updatedAt: updatedAt,
            isPullRequest: pullRequest != nil
        )
    }
}

extension GitHubReviewComment {
    var hostingComment: HostingComment {
        HostingComment(
            id: apiID ?? 0,
            body: body,
            path: path,
            line: line,
            commitID: commitID,
            author: user?.hostingUser,
            htmlURL: htmlURL
        )
    }
}
