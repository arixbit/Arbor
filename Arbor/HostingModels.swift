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

    var id: Int { number ?? 0 }

    enum CodingKeys: String, CodingKey {
        case apiID = "id"
        case number, title, body, state, draft, user, head, base, comments
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
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
    let path: String?
    let line: Int?
    let commitID: String?
    let author: HostingUser?
    let htmlURL: String?
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
            comments: comments
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
