import Foundation
import XCTest
@testable import Arbor

final class GitHubClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testListPullRequestsInjectsTokenAndDecodesOptionalFields() async throws {
        let repository = HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")!
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("secret-token", forOwner: repository.owner)
        defer { try? store.deleteToken(forOwner: repository.owner) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.url?.path, "/repos/acme/arbor/pulls")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "open")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            let data = Data("""
            [{"number":7,"title":"Improve API","state":"open","head":{"ref":"feature","sha":"abc"},"base":{"ref":"main"}}]
            """.utf8)
            return (response, data)
        }

        let client = GitHubClient(session: makeMockSession(), keychain: store)
        let pullRequests = try await client.listPullRequests(for: repository)
        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests[0].number, 7)
        XCTAssertEqual(pullRequests[0].head?.ref, "feature")
        XCTAssertNil(pullRequests[0].user)
    }

    func testCreateIssueEncodesRequestBody() async throws {
        let repository = HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")!
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("issue-token", forOwner: repository.owner)
        defer { try? store.deleteToken(forOwner: repository.owner) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/acme/arbor/issues")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["title"], "Bug report")
            XCTAssertEqual(json["body"], "Details")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("{\"number\":12,\"title\":\"Bug report\",\"state\":\"open\"}".utf8))
        }

        let client = GitHubClient(session: makeMockSession(), keychain: store)
        let issue = try await client.createIssue(for: repository, title: "Bug report", body: "Details")
        XCTAssertEqual(issue.number, 12)
    }

    func testCreatePullRequestAndReviewCommentEncodeBodies() async throws {
        let repository = HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")!
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("write-token", forOwner: repository.owner)
        defer { try? store.deleteToken(forOwner: repository.owner) }

        MockURLProtocol.requestHandler = { request in
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            ))
            if request.url?.path.hasSuffix("/pulls") == true {
                XCTAssertEqual(json["title"] as? String, "Feature")
                XCTAssertEqual(json["head"] as? String, "feature")
                XCTAssertEqual(json["base"] as? String, "main")
                return (response, Data("{\"number\":21,\"title\":\"Feature\",\"state\":\"open\"}".utf8))
            }
            XCTAssertEqual(request.url?.path, "/repos/acme/arbor/pulls/21/comments")
            XCTAssertEqual(json["body"] as? String, "Please rename this.")
            XCTAssertEqual(json["commit_id"] as? String, "abcdef")
            XCTAssertEqual(json["path"] as? String, "Sources/App.swift")
            XCTAssertEqual(json["line"] as? Int, 12)
            XCTAssertEqual(json["side"] as? String, "RIGHT")
            return (response, Data("{\"id\":99,\"body\":\"Please rename this.\"}".utf8))
        }

        let client = GitHubClient(session: makeMockSession(), keychain: store)
        let pullRequest = try await client.createPullRequest(
            for: repository,
            title: "Feature",
            body: "Details",
            head: "feature",
            base: "main"
        )
        XCTAssertEqual(pullRequest.number, 21)
        let comment = try await client.createReviewComment(
            for: repository,
            pullRequestNumber: pullRequest.number ?? 0,
            body: "Please rename this.",
            commitID: "abcdef",
            path: "Sources/App.swift",
            line: 12
        )
        XCTAssertEqual(comment.id, 99)
    }

    func testUnauthorizedResponseIsTyped() async throws {
        let repository = HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")!
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("bad-token", forOwner: repository.owner)
        defer { try? store.deleteToken(forOwner: repository.owner) }

        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("{\"message\":\"Bad credentials\"}".utf8))
        }

        let client = GitHubClient(session: makeMockSession(), keychain: store)
        do {
            _ = try await client.listIssues(for: repository)
            XCTFail("Expected an authentication error")
        } catch let error as GitHubAPIError {
            XCTAssertTrue(error.isAuthenticationFailure)
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testMissingTokenDoesNotIssueNetworkRequest() async throws {
        let repository = HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")!
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        let client = GitHubClient(session: makeMockSession(), keychain: store)

        do {
            _ = try await client.listIssues(for: repository)
            XCTFail("Expected a missing token error")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .missingToken(owner: "acme"))
        }
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw NSError(domain: "GitHubClientTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request body missing"])
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? NSError(domain: "GitHubClientTests", code: 2) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
