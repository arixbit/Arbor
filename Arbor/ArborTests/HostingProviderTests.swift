import XCTest
@testable import Arbor

final class HostingProviderTests: XCTestCase {
    override func tearDown() {
        HostingMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testHostedRemoteActionPresentationMatchesIntelliJGroupSemantics() {
        XCTAssertEqual(hostedRemoteActionPresentation(for: 0), .hidden)
        XCTAssertEqual(hostedRemoteActionPresentation(for: 1), .direct)
        XCTAssertEqual(hostedRemoteActionPresentation(for: 2), .submenu)
        XCTAssertEqual(hostedRemoteActionPresentation(for: 3), .submenu)
    }

    func testRemoteResolutionNeverFallsThroughToFirstRemote() {
        XCTAssertNil(resolveSelectedRemoteName(selectedRemote: nil, availableRemoteNames: []))
        XCTAssertEqual(
            resolveSelectedRemoteName(selectedRemote: nil, availableRemoteNames: ["origin"]),
            "origin"
        )
        XCTAssertNil(
            resolveSelectedRemoteName(
                selectedRemote: nil,
                availableRemoteNames: ["origin", "upstream"]
            )
        )
        XCTAssertEqual(
            resolveSelectedRemoteName(
                selectedRemote: "upstream",
                availableRemoteNames: ["origin", "upstream"]
            ),
            "upstream"
        )
        XCTAssertNil(
            resolveSelectedRemoteName(
                selectedRemote: "missing",
                availableRemoteNames: ["origin", "upstream"]
            )
        )
    }

    func testDefaultFetchRemoteUsesTrackingThenOriginWithoutGuessing() {
        XCTAssertNil(defaultFetchRemoteName(preferredRemote: nil, availableRemoteNames: []))
        XCTAssertEqual(
            defaultFetchRemoteName(preferredRemote: nil, availableRemoteNames: ["origin"]),
            "origin"
        )
        XCTAssertEqual(
            defaultFetchRemoteName(
                preferredRemote: "upstream",
                availableRemoteNames: ["origin", "upstream"]
            ),
            "upstream"
        )
        XCTAssertEqual(
            defaultFetchRemoteName(
                preferredRemote: "missing",
                availableRemoteNames: ["origin", "upstream"]
            ),
            "origin"
        )
        XCTAssertNil(
            defaultFetchRemoteName(
                preferredRemote: nil,
                availableRemoteNames: ["upstream", "mirror"]
            )
        )
    }

    func testPushAfterCommitPreviewSettingsUseProjectOverrideAndSafeDefaults() {
        let suiteName = "Arbor.GitPushAfterCommitPreviewTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-push-preview-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-push-preview-other-\(UUID().uuidString)"
        XCTAssertEqual(
            GitPushAfterCommitSettings.choice(for: projectPath, defaults: suite),
            .always
        )

        suite.set(
            GitPushAfterCommitPreviewChoice.automatic.rawValue,
            forKey: GitPushAfterCommitSettings.globalKey
        )
        XCTAssertEqual(
            GitPushAfterCommitSettings.choice(for: otherProjectPath, defaults: suite),
            .automatic
        )

        GitPushAfterCommitSettings.saveProjectChoice(
            .protectedOnly,
            for: projectPath,
            defaults: suite
        )
        XCTAssertEqual(
            GitPushAfterCommitSettings.choice(for: projectPath, defaults: suite),
            .protectedOnly
        )
        XCTAssertEqual(
            GitPushAfterCommitSettings.choice(for: otherProjectPath, defaults: suite),
            .automatic
        )

        GitPushAfterCommitSettings.saveProjectChoice(
            nil,
            for: projectPath,
            defaults: suite
        )
        XCTAssertEqual(
            GitPushAfterCommitSettings.choice(for: projectPath, defaults: suite),
            .automatic
        )
    }

    func testPushAfterCommitPreviewPolicyMatchesIntelliJSafetyBoundaries() {
        for choice in GitPushAfterCommitPreviewChoice.allCases {
            XCTAssertTrue(
                pushAfterCommitPreviewRequiresUI(
                    choice: choice,
                    hasPushTarget: false,
                    hasCurrentBranch: true,
                    isProtectedBranch: false
                )
            )
            XCTAssertTrue(
                pushAfterCommitPreviewRequiresUI(
                    choice: choice,
                    hasPushTarget: true,
                    hasCurrentBranch: false,
                    isProtectedBranch: false
                )
            )
        }

        XCTAssertTrue(
            pushAfterCommitPreviewRequiresUI(
                choice: .always,
                hasPushTarget: true,
                hasCurrentBranch: true,
                isProtectedBranch: false
            )
        )
        XCTAssertTrue(
            pushAfterCommitPreviewRequiresUI(
                choice: .protectedOnly,
                hasPushTarget: true,
                hasCurrentBranch: true,
                isProtectedBranch: true
            )
        )
        XCTAssertFalse(
            pushAfterCommitPreviewRequiresUI(
                choice: .protectedOnly,
                hasPushTarget: true,
                hasCurrentBranch: true,
                isProtectedBranch: false
            )
        )
        XCTAssertFalse(
            pushAfterCommitPreviewRequiresUI(
                choice: .automatic,
                hasPushTarget: true,
                hasCurrentBranch: true,
                isProtectedBranch: true
            )
        )
    }

    func testPushAfterCommitPreviewNeverAutoPushesAnUnavailableRoot() {
        let missingRoot = "/tmp/arbor-missing-push-root-\(UUID().uuidString)"
        XCTAssertTrue(
            pushAfterCommitRequiresPreview(
                rootPath: missingRoot,
                choice: .automatic,
                protectedBranchPatterns: ["main"]
            )
        )
        XCTAssertTrue(
            pushAfterCommitRequiresPreview(
                rootPath: missingRoot,
                choice: .protectedOnly,
                protectedBranchPatterns: ["main"]
            )
        )
        XCTAssertTrue(
            pushAfterCommitRequiresPreview(
                rootPath: missingRoot,
                choice: .always,
                protectedBranchPatterns: []
            )
        )
    }

    func testPullDialogDefaultsToTrackedRemoteThenOriginThenFirst() {
        XCTAssertNil(defaultPullRemoteName(preferredRemote: nil, availableRemoteNames: []))
        XCTAssertEqual(
            defaultPullRemoteName(preferredRemote: "upstream", availableRemoteNames: ["origin", "upstream"]),
            "upstream"
        )
        XCTAssertEqual(
            defaultPullRemoteName(preferredRemote: "missing", availableRemoteNames: ["origin", "upstream"]),
            "origin"
        )
        XCTAssertEqual(
            defaultPullRemoteName(preferredRemote: nil, availableRemoteNames: ["mirror", "backup"]),
            "mirror"
        )
    }

    func testPullDialogRemoteBranchValidationKeepsRemoteAndBranchExplicit() {
        XCTAssertNil(pullRemoteBranchName(remote: "", branch: "main"))
        XCTAssertNil(pullRemoteBranchName(remote: "origin", branch: ""))
        XCTAssertEqual(
            pullRemoteBranchName(remote: " origin ", branch: " main "),
            "origin/main"
        )
    }

    func testPullDialogOptionsMatchIntelliJIncompatibilities() {
        XCTAssertFalse(
            GitPullDialogOption.rebase.isSuitable(with: [.ffOnly])
        )
        XCTAssertFalse(
            GitPullDialogOption.noCommit.isSuitable(with: [.rebase])
        )
        XCTAssertFalse(
            GitPullDialogOption.noFF.isSuitable(with: [.squash])
        )
        XCTAssertTrue(
            GitPullDialogOption.noVerify.isSuitable(with: [.rebase, .noCommit])
        )
    }

    func testSSHAgentDiagnosticsExposeOnlyStateAndIdentityCount() {
        let diagnostics = SshAgentDiagnostics(
            state: .ready,
            socketPath: "/private/tmp/agent.sock",
            identityCount: 2,
            detailCode: "agent-ready"
        )

        XCTAssertEqual(diagnostics.state, .ready)
        XCTAssertEqual(diagnostics.identityCount, 2)
        XCTAssertEqual(diagnostics.detailCode, "agent-ready")
        XCTAssertFalse(diagnostics.detailCode.contains("ssh-rsa"))
        XCTAssertFalse(diagnostics.detailCode.contains("SHA256:"))
    }

    func testParsesHTTPSGitHubRemote() {
        let repository = HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")
        XCTAssertEqual(repository?.provider, .github)
        XCTAssertEqual(repository?.owner, "acme")
        XCTAssertEqual(repository?.name, "arbor")
        XCTAssertEqual(repository?.apiBaseURL.absoluteString, "https://api.github.com")
        XCTAssertEqual(repository?.pullRequestsURL().absoluteString, "https://github.com/acme/arbor/pulls")
    }

    func testParsesSCPAndSSHRemotes() {
        XCTAssertEqual(HostingProvider.parse(remoteURL: "git@github.com:acme/arbor.git")?.fullName, "acme/arbor")
        XCTAssertEqual(HostingProvider.parse(remoteURL: "ssh://git@github.com/acme/arbor.git")?.fullName, "acme/arbor")
    }

    func testParsesEnterpriseRemote() {
        let enterpriseAPI = URL(string: "https://github.enterprise.example/api/v3")!
        let repository = HostingProvider.parse(
            remoteURL: "https://github.enterprise.example/acme/arbor.git",
            enterpriseAPIBaseURL: enterpriseAPI
        )
        XCTAssertEqual(repository?.fullName, "acme/arbor")
        XCTAssertEqual(repository?.apiBaseURL.absoluteString, "https://github.enterprise.example/api/v3")

        let customAPI = URL(string: "https://git.example/api/v3")!
        let custom = HostingProvider.parse(
            remoteURL: "git@git.example:acme/arbor.git",
            enterpriseAPIBaseURL: customAPI
        )
        XCTAssertEqual(custom?.apiBaseURL, customAPI)
    }

    func testDoesNotInferGitHubFromArbitraryHostnames() {
        XCTAssertNil(HostingProvider.parse(remoteURL: "https://notgithub.example.com/acme/arbor.git"))
    }

    func testRejectsUnsupportedProvider() {
        XCTAssertNil(HostingProvider.parse(remoteURL: "not-a-remote"))
    }

    func testParsesGitLabAndBitbucketRemotes() {
        let gitLab = HostingProvider.parse(remoteURL: "git@gitlab.com:acme/tools/arbor.git")
        XCTAssertEqual(gitLab?.provider, .gitlab)
        XCTAssertEqual(gitLab?.projectPath, "acme/tools/arbor")
        XCTAssertEqual(gitLab?.apiBaseURL.absoluteString, "https://gitlab.com/api/v4")
        XCTAssertEqual(
            gitLab?.pullRequestsURL().absoluteString,
            "https://gitlab.com/acme/tools/arbor/-/merge_requests"
        )

        let bitbucket = HostingProvider.parse(remoteURL: "https://bitbucket.org/acme/arbor.git")
        XCTAssertEqual(bitbucket?.provider, .bitbucket)
        XCTAssertEqual(bitbucket?.fullName, "acme/arbor")
        XCTAssertEqual(bitbucket?.apiBaseURL.absoluteString, "https://api.bitbucket.org/2.0")
        XCTAssertEqual(
            bitbucket?.pullRequestsURL().absoluteString,
            "https://bitbucket.org/acme/arbor/pull-requests"
        )
    }

    func testGitLabClientUsesEncodedProjectPathAndPrivateToken() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "git@gitlab.com:acme/tools/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("gitlab-token", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                "/api/v4/projects/acme%2Ftools%2Farbor/merge_requests"
            )
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("""
            [{"iid":7,"title":"Improve API","description":"Details","state":"opened","source_branch":"feature","target_branch":"main"}]
            """.utf8))
        }

        let client = GitLabClient(
            session: makeHostingMockSession(),
            keychain: store,
            retryDelayOverride: 0
        )
        let pullRequests = try await client.listHostingPullRequests(for: repository)
        XCTAssertEqual(pullRequests.map(\.id), [7])
        XCTAssertEqual(pullRequests.first?.headBranch, "feature")
    }

    func testGitLabProtectedBranchPatternsRespectForcePushFlagAndPagination() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "git@gitlab.com:acme/tools/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("gitlab-token", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                "/api/v4/projects/acme%2Ftools%2Farbor/protected_branches"
            )
            let query = Dictionary(
                uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map {
                    ($0.name, $0.value ?? "")
                } ?? []
            )
            let page = try XCTUnwrap(Int(query["page"] ?? ""))
            XCTAssertEqual(query["per_page"], "100")
            let rows: [[String: Any]]
            if page == 1 {
                rows = [["name": "main", "allow_force_push": false], ["name": "scratch", "allow_force_push": true]]
                    + (0..<98).map { ["name": "release/\($0)", "allow_force_push": false] }
            } else {
                XCTAssertEqual(page, 2)
                rows = [["name": "release/final", "allow_force_push": false]]
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, try JSONSerialization.data(withJSONObject: rows))
        }

        let client = GitLabClient(
            session: makeHostingMockSession(),
            keychain: store,
            retryDelayOverride: 0
        )
        let patterns = try await client.listProtectedBranchPatterns(for: repository)
        XCTAssertTrue(patterns.contains("main"))
        XCTAssertTrue(patterns.contains("release/final"))
        XCTAssertFalse(patterns.contains("scratch"))
        XCTAssertEqual(patterns.count, 100)
    }

    func testGitLabDiscussionIncludesPositionAndMapsNote() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://gitlab.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("gitlab-token", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v4/projects/acme/arbor/merge_requests/7/discussions")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["body"] as? String, "Please rename this.")
            let position = try XCTUnwrap(json["position"] as? [String: Any])
            XCTAssertEqual(position["new_path"] as? String, "Sources/App.swift")
            XCTAssertEqual(position["new_line"] as? Int, 12)
            XCTAssertEqual(position["head_sha"] as? String, "abcdef")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("""
            {"notes":[{"id":99,"body":"Please rename this.","position":{"new_path":"Sources/App.swift","new_line":12,"head_sha":"abcdef"}}]}
            """.utf8))
        }

        let client = GitLabClient(session: makeHostingMockSession(), keychain: store)
        let comment = try await client.postHostingReviewComment(
            for: repository,
            pullRequestID: 7,
            body: "Please rename this.",
            commitID: "abcdef",
            path: "Sources/App.swift",
            line: 12
        )
        XCTAssertEqual(comment.id, 99)
        XCTAssertEqual(comment.path, "Sources/App.swift")
    }

    func testGitLabDetailLoadsApprovalStateAndCommitScopedFiles() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://gitlab.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("gitlab-token", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            switch path {
            case "/api/v4/projects/acme/arbor/merge_requests/7":
                return (response, Data("""
                {"iid":7,"title":"Feature","state":"opened","source_branch":"feature","target_branch":"main","diff_refs":{"base_sha":"base","start_sha":"start","head_sha":"head"}}
                """.utf8))
            case "/api/v4/projects/acme/arbor/merge_requests/7/commits":
                return (response, Data("[{\"id\":\"commitsha\",\"title\":\"Change\"}]".utf8))
            case "/api/v4/projects/acme/arbor/merge_requests/7/changes":
                return (response, Data("{\"changes\":[{\"new_path\":\"all.swift\",\"diff\":\"patch\"}]}".utf8))
            case "/api/v4/projects/acme/arbor/merge_requests/7/discussions":
                return (response, Data("[]".utf8))
            case "/api/v4/projects/acme/arbor/merge_requests/7/approvals":
                return (response, Data("{\"approved\":true}".utf8))
            case "/api/v4/projects/acme/arbor/repository/commits/commitsha/diff":
                return (response, Data("[{\"new_path\":\"commit.swift\",\"new_file\":true,\"diff\":\"commit patch\"}]".utf8))
            default:
                throw NSError(domain: "HostingProviderTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected GitLab path \(path)"
                ])
            }
        }

        let client = GitLabClient(session: makeHostingMockSession(), keychain: store)
        let detail = try await client.loadGitLabChangeRequestDetail(for: repository, iid: 7)
        XCTAssertEqual(detail.baseRevision, "base")
        XCTAssertEqual(detail.headRevision, "head")
        XCTAssertFalse(detail.capabilities.canApprove)
        XCTAssertTrue(detail.capabilities.canRevokeApproval)

        let files = try await client.loadGitLabCommitFiles(for: repository, commitID: "commitsha")
        XCTAssertEqual(files.map(\.path), ["commit.swift"])
    }

    func testBitbucketClientUsesBasicAuthAndDecodesPage() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://bitbucket.org/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("app-password", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            let credentials = Data("acme:app-password".utf8).base64EncodedString()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic \(credentials)")
            XCTAssertEqual(request.url?.path, "/2.0/repositories/acme/arbor/pullrequests")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("""
            {"values":[{"id":21,"title":"Feature","state":"OPEN","source":{"branch":{"name":"feature"}},"destination":{"branch":{"name":"main"}}}]}
            """.utf8))
        }

        let client = BitbucketClient(session: makeHostingMockSession(), keychain: store)
        let pullRequests = try await client.listHostingPullRequests(for: repository)
        XCTAssertEqual(pullRequests.first?.id, 21)
        XCTAssertEqual(pullRequests.first?.baseBranch, "main")
    }

    func testBitbucketForceRestrictionsReturnOnlyGlobPatternsAndPaginate() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://bitbucket.org/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("app-password", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            let credentials = Data("acme:app-password".utf8).base64EncodedString()
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic \(credentials)")
            XCTAssertEqual(request.url?.path, "/2.0/repositories/acme/arbor/branch-restrictions")
            let query = Dictionary(
                uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map {
                    ($0.name, $0.value ?? "")
                } ?? []
            )
            XCTAssertEqual(query["kind"], "force")
            XCTAssertEqual(query["pagelen"], "100")
            let page = try XCTUnwrap(Int(query["page"] ?? ""))
            let values: [[String: Any]]
            if page == 1 {
                values = [[
                    "kind": "force",
                    "branch_match_kind": "glob",
                    "pattern": "main",
                ], [
                    "kind": "force",
                    "branch_match_kind": "branching_model",
                    "pattern": "ignored",
                ]] + (0..<98).map { index in
                    ["kind": "force", "branch_match_kind": "glob", "pattern": "release/\(index)"]
                }
            } else {
                XCTAssertEqual(page, 2)
                values = [[
                    "kind": "force",
                    "branch_match_kind": "glob",
                    "pattern": "release/final",
                ]]
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, try JSONSerialization.data(withJSONObject: ["values": values]))
        }

        let client = BitbucketClient(session: makeHostingMockSession(), keychain: store)
        let patterns = try await client.listProtectedBranchPatterns(for: repository)
        XCTAssertTrue(patterns.contains("main"))
        XCTAssertTrue(patterns.contains("release/final"))
        XCTAssertFalse(patterns.contains("ignored"))
        XCTAssertEqual(patterns.count, 100)
    }

    func testRateLimit429RetriesThenSucceeds() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://gitlab.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("retry-token", for: repository)
        defer { try? store.deleteToken(for: repository) }
        var requestCount = 0

        HostingMockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "0"]
                ))
                return (response, Data("{\"message\":\"slow down\"}".utf8))
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("{\"username\":\"arix\"}".utf8))
        }

        let client = GitLabClient(
            session: makeHostingMockSession(),
            keychain: store,
            retryDelayOverride: 0
        )
        let user = try await client.currentHostingUser(for: repository)
        XCTAssertEqual(user.login, "arix")
        XCTAssertEqual(requestCount, 2)
    }

    func testGitHub403WithEmptyRateLimitRetries() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("github-token", forOwner: repository.owner)
        defer { try? store.deleteToken(forOwner: repository.owner) }
        var requestCount = 0

        HostingMockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount < 3 {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "0", "Retry-After": "0"]
                ))
                return (response, Data("{\"message\":\"API rate limit exceeded\"}".utf8))
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("[]".utf8))
        }

        let client = GitHubClient(session: makeHostingMockSession(), keychain: store)
        let issues = try await client.listIssues(for: repository)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(requestCount, 3)
    }

    func testGitHubDeviceFlowPollsPendingThenStoresToken() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        defer { try? store.deleteToken(for: repository) }
        var tokenPollCount = 0

        HostingMockURLProtocol.requestHandler = { request in
            let path = request.url?.path
            if path == "/login/device/code" {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = String(data: try Self.bodyData(from: request), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("client_id=client-id"))
                XCTAssertTrue(body.contains("scope=repo%20read%3Auser"))
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
                return (response, Data("""
                {"device_code":"device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":60,"interval":0}
                """.utf8))
            }

            XCTAssertEqual(path, "/login/oauth/access_token")
            tokenPollCount += 1
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            if tokenPollCount == 1 {
                return (response, Data("{\"error\":\"authorization_pending\"}".utf8))
            }
            return (response, Data("{\"access_token\":\"oauth-token\",\"token_type\":\"bearer\"}".utf8))
        }

        let flow = GitHubOAuthFlow(
            clientID: "client-id",
            session: makeHostingMockSession(),
            keychain: store,
            deviceCodeURL: URL(string: "https://github.com/login/device/code")!,
            accessTokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            sleepOverride: 0
        )
        let authorization = try await flow.startDeviceAuthorization()
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        let token = try await flow.authorizeAndStoreToken(for: repository, authorization: authorization)
        XCTAssertEqual(token, "oauth-token")
        XCTAssertEqual(try store.token(for: repository), "oauth-token")
        XCTAssertEqual(tokenPollCount, 2)
    }

    func testGitHubProtectedBranchPatternsUseGraphQLPagination() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://github.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("github-token", for: repository)
        defer { try? store.deleteToken(for: repository) }
        var cursors: [String?] = []

        HostingMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/graphql")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertTrue((json["query"] as? String)?.contains("branchProtectionRules") == true)
            let variables = try XCTUnwrap(json["variables"] as? [String: Any])
            XCTAssertEqual(variables["repoOwner"] as? String, "acme")
            XCTAssertEqual(variables["repoName"] as? String, "arbor")
            let cursor = variables["cursor"] as? String
            cursors.append(cursor)

            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            if cursor == nil {
                return (response, Data("""
                {"data":{"repository":{"branchProtectionRules":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"},"nodes":[{"pattern":"main"},{"pattern":"release/*"}]}}}}
                """.utf8))
            }
            XCTAssertEqual(cursor, "cursor-1")
            return (response, Data("""
            {"data":{"repository":{"branchProtectionRules":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"pattern":"feature/*"},{"pattern":"main"}]}}}}
            """.utf8))
        }

        let client = GitHubClient(session: makeHostingMockSession(), keychain: store)
        let patterns = try await client.listProtectedBranchPatterns(for: repository)
        XCTAssertEqual(patterns, ["main", "release/*", "feature/*"])
        XCTAssertEqual(cursors, [nil, "cursor-1"])
    }

    private func makeHostingMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostingMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let bodyStream = request.httpBodyStream else {
            throw NSError(domain: "HostingProviderTests", code: 1)
        }
        bodyStream.open()
        defer { bodyStream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bodyStream.hasBytesAvailable {
            let count = bodyStream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class GitProtectedBranchRulesTests: XCTestCase {
    func testDefaultPatternsProtectMainAndMasterOnly() {
        let patterns = GitProtectedBranchRules.patterns(from: GitProtectedBranchRules.defaultPatterns)
        XCTAssertTrue(GitProtectedBranchRules.matches("main", patterns: patterns))
        XCTAssertTrue(GitProtectedBranchRules.matches("refs/heads/master", patterns: patterns))
        XCTAssertFalse(GitProtectedBranchRules.matches("feature/main", patterns: patterns))
    }

    func testConfiguredPatternsUseAnchoredRegularExpressions() {
        let patterns = GitProtectedBranchRules.patterns(from: "release/.*\n^hotfix$")
        XCTAssertTrue(GitProtectedBranchRules.matches("release/2026.08", patterns: patterns))
        XCTAssertTrue(GitProtectedBranchRules.matches("hotfix", patterns: patterns))
        XCTAssertFalse(GitProtectedBranchRules.matches("hotfix/urgent", patterns: patterns))
    }

    func testInvalidPatternsDoNotBlockUnrelatedPushes() {
        let patterns = GitProtectedBranchRules.patterns(from: "[")
        XCTAssertFalse(GitProtectedBranchRules.matches("main", patterns: patterns))
    }

    func testGitHubMasksMatchIntelliJPatternUtilSemantics() {
        XCTAssertEqual(GitProtectedBranchRules.githubMaskToRegex("release/*"), "release\\/.*")
        XCTAssertEqual(GitProtectedBranchRules.githubMaskToRegex("feature?"), "feature.")
        XCTAssertEqual(GitProtectedBranchRules.githubMaskToRegex("release.v1"), "release\\.v1")

        let patterns = [GitProtectedBranchRules.githubMaskToRegex("release/*")]
        XCTAssertTrue(GitProtectedBranchRules.matches("release/2026.08", patterns: patterns))
        XCTAssertFalse(GitProtectedBranchRules.matches("release-candidate", patterns: patterns))
    }

    func testRemotePatternsAreProjectScopedAndCanBeCombinedSafely() {
        let suiteName = "Arbor.GitProtectedBranchRulesTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let path = "/tmp/arbor-protected-\(UUID().uuidString)"
        GitProtectedBranchRules.saveRemotePatterns(["release/.*", "main"], for: path, defaults: suite)

        XCTAssertEqual(
            GitProtectedBranchRules.loadRemotePatterns(for: path, defaults: suite),
            ["release/.*", "main"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.combinedPatterns(
                localRawValue: "main\nfeature/.*",
                remotePatterns: ["release/.*", "main"],
                synchronize: true
            ),
            ["main", "feature/.*", "release/.*"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.combinedPatterns(
                localRawValue: "main",
                remotePatterns: ["release/.*"],
                synchronize: false
            ),
            ["main"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizedRemotePatterns(
                cachedPatterns: ["main", "release/.*"],
                fetchedPatterns: ["main", "hotfix"],
                hasProviderFailure: true
            ),
            ["hotfix", "main", "release/.*"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizedRemotePatterns(
                cachedPatterns: ["stale"],
                fetchedPatterns: ["main"],
                hasProviderFailure: false
            ),
            ["main"]
        )
    }

    func testMultiRootRemotePatternsDoNotCrossProtectRepositories() {
        let firstRoot = "/tmp/arbor-protected-root-a-\(UUID().uuidString)"
        let secondRoot = "/tmp/arbor-protected-root-b-\(UUID().uuidString)"
        let patternsByRoot = [
            URL(fileURLWithPath: firstRoot).standardizedFileURL.path: ["release/.*"],
            URL(fileURLWithPath: secondRoot).standardizedFileURL.path: ["stable"]
        ]

        XCTAssertEqual(
            GitProtectedBranchRules.remotePatterns(
                forRootPath: firstRoot,
                primaryPatterns: ["main"],
                patternsByRoot: patternsByRoot
            ),
            ["release/.*"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.remotePatterns(
                forRootPath: secondRoot,
                primaryPatterns: ["main"],
                patternsByRoot: patternsByRoot
            ),
            ["stable"]
        )
        XCTAssertTrue(
            GitProtectedBranchRules.matches(
                "stable",
                patterns: GitProtectedBranchRules.remotePatterns(
                    forRootPath: secondRoot,
                    primaryPatterns: ["main"],
                    patternsByRoot: patternsByRoot
                )
            )
        )
        XCTAssertFalse(
            GitProtectedBranchRules.matches(
                "release/2026.08",
                patterns: GitProtectedBranchRules.remotePatterns(
                    forRootPath: secondRoot,
                    primaryPatterns: ["main"],
                    patternsByRoot: patternsByRoot
                )
            )
        )
    }

    func testProjectProtectedBranchSettingsOverrideAndThenInheritGlobalValues() {
        let suiteName = "Arbor.GitProtectedBranchRulesTests.project.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("main\nmaster", forKey: GitProtectedBranchRules.userDefaultsKey)
        suite.set(false, forKey: GitProtectedBranchRules.synchronizeKey)

        let path = "/tmp/arbor-protected-project-\(UUID().uuidString)"
        let otherPath = "/tmp/arbor-protected-other-\(UUID().uuidString)"
        XCTAssertEqual(
            GitProtectedBranchRules.globalRawValue(from: suite),
            "main\nmaster"
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: path, defaults: suite),
            false
        )

        GitProtectedBranchRules.saveProjectPatterns("release/.*", for: path, defaults: suite)
        GitProtectedBranchRules.saveProjectSynchronize(true, for: path, defaults: suite)
        XCTAssertEqual(
            GitProtectedBranchRules.projectRawValue(for: path, defaults: suite),
            "release/.*"
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: path, defaults: suite),
            true
        )
        XCTAssertNil(GitProtectedBranchRules.projectRawValue(for: otherPath, defaults: suite))
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: otherPath, defaults: suite),
            false
        )

        GitProtectedBranchRules.saveProjectPatterns(nil, for: path, defaults: suite)
        GitProtectedBranchRules.saveProjectSynchronize(nil, for: path, defaults: suite)
        XCTAssertNil(GitProtectedBranchRules.projectRawValue(for: path, defaults: suite))
        XCTAssertNil(GitProtectedBranchRules.projectSynchronizeValue(for: path, defaults: suite))
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: path, defaults: suite),
            false
        )
    }
}

final class GitDeleteOnMergeOptionTests: XCTestCase {
    func testDefaultIsToProposeDeletion() {
        let suiteName = "Arbor.GitDeleteOnMergeOptionTests.default.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            GitDeleteOnMergeOption.choice(from: suite),
            .propose
        )
    }

    func testConfiguredOptionIsLoadedAndInvalidValuesUseDefault() {
        let suiteName = "Arbor.GitDeleteOnMergeOptionTests.configured.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        suite.set(GitDeleteOnMergeOption.delete.rawValue, forKey: GitDeleteOnMergeOption.key)
        XCTAssertEqual(GitDeleteOnMergeOption.choice(from: suite), .delete)

        suite.set("invalid", forKey: GitDeleteOnMergeOption.key)
        XCTAssertEqual(GitDeleteOnMergeOption.choice(from: suite), .propose)
    }

    func testOnlyEligibleLocalBranchesUseConfiguredAction() {
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.delete, canDeleteBranch: true),
            .delete
        )
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.propose, canDeleteBranch: true),
            .propose
        )
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.nothing, canDeleteBranch: true),
            .nothing
        )
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.delete, canDeleteBranch: false),
            .nothing
        )
    }

    func testMultiRootMergeDeleteTargetsAreRootQualifiedAndDeduplicated() {
        let candidates = [
            MultiRootMergeDeleteCandidate(rootPath: "/project/app", displayName: "App"),
            MultiRootMergeDeleteCandidate(rootPath: "/project/docs", displayName: "Docs"),
            MultiRootMergeDeleteCandidate(rootPath: "/project/app", displayName: "Duplicate App")
        ]

        XCTAssertEqual(
            multiRootMergeDeleteTargets(
                selectedRootPaths: ["/project/docs/", "/project/app"],
                candidates: candidates
            ),
            [
                MultiRootMergeDeleteCandidate(rootPath: "/project/app", displayName: "App"),
                MultiRootMergeDeleteCandidate(rootPath: "/project/docs", displayName: "Docs")
            ]
        )
    }
}

final class GitUpdateNotificationSummaryTests: XCTestCase {
    func testUpdatedCommitCountParsesSuccessfulAndRestoreMessages() {
        XCTAssertEqual(
            ContentView.updatedCommitCount(from: "updated 3 commits and restored local changes"),
            3
        )
        XCTAssertEqual(ContentView.updatedCommitCount(from: "updated 0 commits"), 0)
        XCTAssertNil(ContentView.updatedCommitCount(from: "detached HEAD"))
    }

    func testSkippedRootsAreGroupedByReasonAndSorted() {
        let results = [
            RootOperationResult(
                rootPath: "/b",
                displayName: "B",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/a",
                displayName: "A",
                success: true,
                skipped: true,
                message: "no configured upstream"
            ),
            RootOperationResult(
                rootPath: "/c",
                displayName: "C",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]

        XCTAssertEqual(
            ContentView.skippedUpdateRootDetails(results),
            ["B, C (detached HEAD)", "A (no configured upstream)"]
        )
    }

    func testSuccessDetailIncludesCommitCountAndSkippedReasons() {
        let results = [
            RootOperationResult(
                rootPath: "/repo",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated 2 commits"
            ),
            RootOperationResult(
                rootPath: "/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateSuccessDetail(results),
            "1 updated · 2 commits · Skipped: Docs (detached HEAD)"
        )
        XCTAssertEqual(
            ContentView.multiRootUpdateSuccessDetail(results, updatedFilesCount: 3),
            "3 files updated in 2 commits · Skipped: Docs (detached HEAD)"
        )
    }

    func testUpdateProjectRequiresAnEligibleRootWhenAllRootsAreSkipped() {
        let unavailable = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: true,
                message: "no configured upstream"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]
        XCTAssertFalse(ContentView.updateProjectHasEligibleRoot(unavailable))

        let partiallyEligible = unavailable + [
            RootOperationResult(
                rootPath: "/workspace/service",
                displayName: "Service",
                success: true,
                skipped: false,
                message: "updated 0 commits"
            )
        ]
        XCTAssertTrue(ContentView.updateProjectHasEligibleRoot(partiallyEligible))

        let failed = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: false,
                skipped: false,
                message: "another Git operation is already in progress"
            )
        ]
        XCTAssertFalse(ContentView.updateProjectHasEligibleRoot(failed))
    }

    func testUpdateProjectNotReadyClassifierCoversEngineAndLegacyMessages() {
        let ready = RootOperationResult(
            rootPath: "/workspace/app",
            displayName: "App",
            success: true,
            skipped: false,
            message: "updated 0 commits"
        )
        XCTAssertFalse(ContentView.updateProjectIsNotReady([ready]))
        XCTAssertTrue(ContentView.updateProjectIsNotReady([
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: false,
                skipped: false,
                message: "update not ready: unresolved conflicts remain"
            )
        ]))
        XCTAssertTrue(ContentView.updateProjectIsNotReady([
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: false,
                skipped: false,
                message: "another Git operation is already in progress"
            )
        ]))
        XCTAssertFalse(ContentView.updateProjectIsNotReady([
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]))
    }

    func testUnknownCommitCountDoesNotLookLikeNothingToUpdate() {
        let results = [
            RootOperationResult(
                rootPath: "/submodule",
                displayName: "Submodule",
                success: true,
                skipped: false,
                message: "updated detached submodule via parent App"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateSuccessDetail(results),
            "1 updated"
        )
    }

    func testUpdateSessionRevisionRangesOnlyIncludeChangedSuccessfulRoots() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/workspace/app/.",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated 2 commits"
            ),
            RootOperationResult(
                rootPath: "/workspace/failed",
                displayName: "Failed",
                success: false,
                skipped: false,
                message: "conflict"
            ),
            RootOperationResult(
                rootPath: "/workspace/unchanged",
                displayName: "Unchanged",
                success: true,
                skipped: false,
                message: "updated 0 commits"
            )
        ]

        let ranges = ContentView.updateSessionRevisionRanges(
            previousHeads: [
                "/workspace/app": "app-old",
                "/workspace/docs": "docs-old",
                "/workspace/failed": "failed-old",
                "/workspace/unchanged": "same"
            ],
            currentHeads: [
                "/workspace/app": "app-new",
                "/workspace/docs": "docs-new",
                "/workspace/failed": "failed-new",
                "/workspace/unchanged": "same"
            ],
            results: results
        )

        XCTAssertEqual(ranges, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-old",
                newRevision: "app-new"
            )
        ])
    }

    func testJoinedRevisionRangesKeepOriginalBoundaryAcrossRepeatedPushRecovery() {
        let joined = ContentView.joinedRevisionRanges(
            existing: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app/.",
                    oldRevision: "before-first-update",
                    newRevision: "after-first-update"
                ),
                PersistedLogRevisionRange(
                    rootPath: "/workspace/docs",
                    oldRevision: "docs-before",
                    newRevision: "docs-after"
                )
            ],
            latest: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app",
                    oldRevision: "before-second-update",
                    newRevision: "after-second-update"
                )
            ]
        )

        XCTAssertEqual(joined, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "before-first-update",
                newRevision: "after-second-update"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/docs",
                oldRevision: "docs-before",
                newRevision: "docs-after"
            )
        ])
    }

    func testMultiRootPushRetryRangesRetainCompletedRootsAndAppendLaterSuccesses() {
        let initialResults = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "pushed App"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: false,
                skipped: false,
                message: "push rejected"
            )
        ]
        let completedInitially = ContentView.successfulPushRevisionRanges(
            pendingRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app",
                    oldRevision: "app-base",
                    newRevision: "app-tip"
                ),
                PersistedLogRevisionRange(
                    rootPath: "/workspace/docs",
                    oldRevision: "docs-base",
                    newRevision: "docs-tip"
                )
            ],
            results: initialResults
        )

        let joined = ContentView.joinedRevisionRanges(
            existing: completedInitially,
            latest: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/docs/.",
                    oldRevision: "docs-base-after-update",
                    newRevision: "docs-tip-after-update"
                )
            ]
        )

        XCTAssertEqual(joined, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-base",
                newRevision: "app-tip"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/docs",
                oldRevision: "docs-base-after-update",
                newRevision: "docs-tip-after-update"
            )
        ])
    }

    func testMultiRootPushRetryRowsRetainSuccessfulRootsAndReplaceRetriedRoots() {
        let initial = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "pushed App"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: false,
                skipped: false,
                message: "push rejected"
            )
        ]
        let retry = [
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: false,
                message: "pushed Docs"
            )
        ]

        let merged = mergeFeedbackResultRows(
            preserved: feedbackResultRows(from: initial),
            retry: feedbackResultRows(from: retry)
        )

        XCTAssertEqual(merged.map(\.rootPath), [
            "/workspace/app",
            "/workspace/docs"
        ])
        XCTAssertEqual(merged.map(\.state), [.success, .success])
        XCTAssertEqual(merged.map(\.detail), ["pushed App", "pushed Docs"])
    }

    func testTargetedForcePushDoesNotPropagateToNonStaleRetryRoots() {
        let stale = RootOperationResult(
            rootPath: "/workspace/stale",
            displayName: "Stale",
            success: false,
            skipped: false,
            message: "push rejected: stale info"
        )
        let rejected = RootOperationResult(
            rootPath: "/workspace/rejected",
            displayName: "Rejected",
            success: false,
            skipped: false,
            message: "push rejected for origin/main: non-fast-forward"
        )

        let staleOnly = multiRootPushRetryForceOptions(
            requestedForce: true,
            requestedForceWithLease: false,
            hasPriorResultRows: true,
            retryResults: [stale]
        )
        let mixed = multiRootPushRetryForceOptions(
            requestedForce: true,
            requestedForceWithLease: false,
            hasPriorResultRows: true,
            retryResults: [stale, rejected]
        )

        XCTAssertTrue(staleOnly.force)
        XCTAssertFalse(mixed.force)
        XCTAssertFalse(mixed.forceWithLease)
    }

    func testPushRecoveryRevisionRangesIncludeOnlyRootsThatUpdatedAndRepublished() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated and pushed origin/main"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD; Push recovery update skipped"
            ),
            RootOperationResult(
                rootPath: "/workspace/failed",
                displayName: "Failed",
                success: false,
                skipped: false,
                message: "push rejected"
            )
        ]

        let ranges = ContentView.updateSessionRevisionRanges(
            previousHeads: [
                "/workspace/app": "app-before",
                "/workspace/docs": "docs-before",
                "/workspace/failed": "failed-before"
            ],
            currentHeads: [
                "/workspace/app": "app-after",
                "/workspace/docs": "docs-after",
                "/workspace/failed": "failed-after"
            ],
            results: results
        )

        XCTAssertEqual(ranges, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-before",
                newRevision: "app-after"
            )
        ])
    }

    func testSuccessfulPushRevisionRangesOnlyIncludeCompletedRoots() {
        let pendingRanges = [
            PersistedLogRevisionRange(
                rootPath: "/workspace/docs/.",
                oldRevision: "docs-before",
                newRevision: "docs-after"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-before",
                newRevision: "app-after"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/skipped",
                oldRevision: "skipped-before",
                newRevision: "skipped-after"
            )
        ]
        let results = [
            RootOperationResult(
                rootPath: "/workspace/app/.",
                displayName: "App",
                success: true,
                skipped: false,
                message: "pushed App"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: false,
                skipped: false,
                message: "rejected"
            ),
            RootOperationResult(
                rootPath: "/workspace/skipped",
                displayName: "Skipped",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]

        XCTAssertEqual(
            ContentView.successfulPushRevisionRanges(
                pendingRanges: pendingRanges,
                results: results
            ),
            [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app",
                    oldRevision: "app-before",
                    newRevision: "app-after"
                )
            ]
        )
    }
}

final class GitBranchesPopupSettingsTests: XCTestCase {
    func testPopupSettingsAreProjectScopedAndUseIntelliJDefaults() {
        let suiteName = "Arbor.GitBranchesPopupSettingsTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-branches-popup-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-branches-popup-other-\(UUID().uuidString)"
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByRepositoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: projectPath,
                defaults: suite
            ),
            GitBranchesPopupSettings.defaultLogSelectionAction
        )

        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.showRecentBranchesKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.filterByRepositoryKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.filterByActionInPopupKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.groupByRepositoryKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.groupByDirectoryKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.showTagsKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            "filter",
            GitBranchesPopupSettings.logSelectionActionKey,
            for: projectPath,
            defaults: suite
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: otherProjectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: otherProjectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: otherProjectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: projectPath,
                defaults: suite
            ),
            "filter"
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: otherProjectPath,
                defaults: suite
            ),
            GitBranchesPopupSettings.defaultLogSelectionAction
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.favorites(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
        GitBranchesPopupSettings.saveFavorites(
            ["local:/repo-a:feature/login", "remote:/repo-a:origin/main"],
            for: projectPath,
            defaults: suite
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.favorites(
                for: projectPath,
                defaults: suite
            ),
            ["local:/repo-a:feature/login", "remote:/repo-a:origin/main"]
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.favorites(
                for: otherProjectPath,
                defaults: suite
            ).isEmpty
        )
        GitBranchesPopupSettings.saveFavorites([], for: projectPath, defaults: suite)
        XCTAssertTrue(
            GitBranchesPopupSettings.favorites(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
    }

    func testCollapsedDirectoryGroupsAreProjectScopedAndStable() {
        let suiteName = "Arbor.GitBranchesPopupSettingsTests.collapsed-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-branches-popup-collapsed-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-branches-popup-collapsed-other-\(UUID().uuidString)"
        let groups: Set<String> = [
            "group:/repo/local/feature",
            "group:/repo/local"
        ]

        XCTAssertTrue(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
        GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
            groups,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
            ["group:log/local"],
            for: projectPath,
            setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey,
            defaults: suite
        )

        XCTAssertEqual(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                defaults: suite
            ),
            groups
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey,
                defaults: suite
            ),
            ["group:log/local"]
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: otherProjectPath,
                defaults: suite
            ).isEmpty
        )

        GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
            [],
            for: projectPath,
            defaults: suite
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
    }
}

final class GitExecutableSettingsTests: XCTestCase {
    func testProjectOverridePersistsIndependentlyAndCanInheritAgain() {
        let suiteName = "Arbor.GitExecutableSettingsTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-git-executable-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-git-executable-other-\(UUID().uuidString)"

        XCTAssertNil(GitExecutableSettings.projectOverride(for: projectPath, defaults: suite))
        GitExecutableSettings.saveProjectOverride(" /usr/local/bin/git ", for: projectPath, defaults: suite)

        XCTAssertEqual(
            GitExecutableSettings.projectOverride(for: projectPath, defaults: suite),
            "/usr/local/bin/git"
        )
        XCTAssertNil(GitExecutableSettings.projectOverride(for: otherProjectPath, defaults: suite))

        GitExecutableSettings.saveProjectOverride(nil, for: projectPath, defaults: suite)
        XCTAssertNil(GitExecutableSettings.projectOverride(for: projectPath, defaults: suite))
    }

    func testRegisteredRootsNormalizeAndDeduplicateProjectRoots() {
        let projectPath = "/tmp/arbor-git-executable/project/.."
        let roots = GitExecutableSettings.registeredRoots(
            projectPath: projectPath,
            repositoryRoot: "/tmp/arbor-git-executable/repository/..",
            discoveredRoots: [
                "/tmp/arbor-git-executable/repository",
                "/tmp/arbor-git-executable/other/../repository"
            ]
        )

        XCTAssertEqual(
            roots,
            [
                "/tmp/arbor-git-executable",
                "/tmp/arbor-git-executable/repository"
            ]
        )
    }
}

final class BranchDirectoryTreeTests: XCTestCase {
    func testBranchDashboardReferencesExposeRootQualifiedFavoriteIDs() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let remote = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        XCTAssertEqual(local.favoriteID, "local:/repo-a:feature/login")
        XCTAssertEqual(remote.favoriteID, "remote:/repo-b:origin/feature/login")
        XCTAssertNotEqual(local.favoriteID, remote.favoriteID)
    }

    func testLogBranchSelectionActionPersistsTheThreeIntellijModes() {
        XCTAssertEqual(
            LogBranchSelectionAction.allCases.map(\.rawValue),
            ["navigate", "filter", "none"]
        )
        XCTAssertEqual(LogBranchSelectionAction(rawValue: "navigate")?.title, "Navigate Log")
        XCTAssertEqual(LogBranchSelectionAction(rawValue: "filter")?.title, "Filter Log")
        XCTAssertEqual(LogBranchSelectionAction(rawValue: "none")?.title, "Select Only")
    }

    func testLogBranchDashboardFiltersAreRootQualifiedAndExcludeTags() {
        func reference(
            _ rootPath: String,
            _ name: String,
            _ kind: BranchDashboardReferenceKind
        ) -> BranchDashboardReference {
            BranchDashboardReference(
                rootPath: rootPath,
                name: name,
                kind: kind,
                remote: kind == .remote ? "origin" : nil,
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: kind == .remote,
                isProtected: false
            )
        }

        XCTAssertEqual(
            logBranchFiltersForDashboardSelection([
                reference("/repo-a", "v1.0", .tag),
                reference("/repo-a", "feature/login", .local),
                reference("/repo-b", "origin/main", .remote),
                reference("/repo-a", "feature/login", .local),
                reference("/repo-a", "HEAD", .head)
            ]),
            [
                LogRootBranchFilter(rootPath: "/repo-a", branch: "feature/login"),
                LogRootBranchFilter(rootPath: "/repo-b", branch: "origin/main"),
                LogRootBranchFilter(rootPath: "/repo-a", branch: "HEAD")
            ]
        )
    }

    func testPrefixTreePreservesHierarchyAndScopesCollapsedGroups() {
        let rows = branchDirectoryRows(
            for: ["feature/login", "feature/ui", "hotfix/one"],
            grouped: true,
            scope: "local"
        )

        XCTAssertEqual(
            rows.map { "\($0.name)|\($0.depth)|\($0.isGroup)" },
            [
                "feature|0|true",
                "login|1|false",
                "ui|1|false",
                "hotfix|0|true",
                "one|1|false"
            ]
        )
        XCTAssertTrue(rows[0].id.hasPrefix("group:local:"))
        XCTAssertNotEqual(
            branchDirectoryRows(for: ["feature/login"], grouped: true, scope: "remote")[0].id,
            rows[0].id
        )

        let visible = visibleBranchDirectoryRows(
            rows,
            collapsedGroups: [rows[0].id]
        )
        XCTAssertEqual(
            visible.map { "\($0.name)|\($0.depth)|\($0.isGroup)" },
            [
                "feature|0|true",
                "hotfix|0|true",
                "one|1|false"
            ]
        )
    }

    func testBranchSearchSupportsWordsComponentsAndFuzzyInitials() {
        XCTAssertTrue(branchSearchMatches("feature/login", query: "login"))
        XCTAssertTrue(branchSearchMatches("feature/login", query: "fl"))
        XCTAssertTrue(branchSearchMatches("feature/login", query: "FEATURE"))
        XCTAssertTrue(branchSearchMatches("hotfix/login", query: "hot login"))
        XCTAssertFalse(branchSearchMatches("feature/login", query: "release"))

        let targets = [
            BranchTreeTarget(id: "recent", value: "feature/login", title: "login", kind: .recent),
            BranchTreeTarget(id: "local", value: "feature/login-long", title: "login-long", kind: .local),
            BranchTreeTarget(id: "remote", value: "origin/feature/login", title: "login", kind: .remote)
        ]
        XCTAssertEqual(
            bestBranchTreeTargetID(query: "feature/login", targets: targets),
            "recent"
        )
        XCTAssertEqual(
            bestBranchTreeTargetID(query: "", targets: targets, preserving: "local"),
            "local"
        )
    }

    func testBranchDashboardSingleLocalSelectionUsesRootScopedActionGroup() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.update))
        XCTAssertTrue(availability.contains(.merge))
        XCTAssertTrue(availability.contains(.rebase))
        XCTAssertTrue(availability.contains(.push))
        XCTAssertTrue(availability.contains(.unsetUpstream))
        XCTAssertTrue(availability.contains(.rename))
        XCTAssertTrue(availability.contains(.deleteLocal))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.setUpstream))
    }

    func testNewWorkingTreeRemainsSingleRootScopedForMultiRootReferences() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        XCTAssertTrue(BranchDashboardActionAvailability.resolve(selection: [first]).contains(.createWorktree))
        XCTAssertTrue(BranchDashboardActionAvailability.resolve(selection: [second]).contains(.createWorktree))
        XCTAssertFalse(BranchDashboardActionAvailability.resolve(selection: [first, second]).contains(.createWorktree))
        XCTAssertNotEqual(first.rootPath, second.rootPath)
    }

    func testBranchRenameValidationMirrorsIntelliJLocalAndRemoteConflicts() {
        XCTAssertNil(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "topic",
                localBranchNames: ["feature/login", "feature/ui"],
                remoteBranchNames: ["origin/release"]
            )
        )
        XCTAssertEqual(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "feature",
                localBranchNames: ["feature/login", "feature/ui"],
                remoteBranchNames: []
            ),
            "Branch feature conflicts with an existing local branch."
        )
        XCTAssertEqual(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "release",
                localBranchNames: ["feature/login"],
                remoteBranchNames: ["origin/release"]
            ),
            "Branch release clashes with a remote branch."
        )
        XCTAssertEqual(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "feature/login",
                localBranchNames: ["feature/login"],
                remoteBranchNames: []
            ),
            "The new name must be different."
        )
    }

    func testLocalBranchPushRemainsVisibleWithoutConfiguredRemote() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/local-only",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [local])

        XCTAssertTrue(availability.contains(.push))
        XCTAssertFalse(availability.contains(.update))
    }

    func testBranchDashboardHeadSelectionUsesHeadOnlyActions() {
        let head = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head])

        XCTAssertTrue(availability.contains(.filterLog))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.checkout))
        XCTAssertFalse(availability.contains(.merge))
        XCTAssertFalse(availability.contains(.deleteSelected))
    }

    func testBranchDashboardUnbornHeadDisablesBranchCreationActions() {
        let head = BranchDashboardReference(
            rootPath: "/repo-fresh",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head])

        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.isEnabled(.checkoutAsNewBranch))
        XCTAssertFalse(availability.isEnabled(.createWorktree))
    }

    func testBranchDashboardHeadAndBranchSelectionExposesPairComparisons() {
        let head = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: true,
            headBranchName: "main"
        )
        let branch = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head, branch])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.isEnabled(.compareSelected))
        XCTAssertTrue(availability.isEnabled(.compareSelectedFiles))
        XCTAssertEqual(
            branchDashboardComparisonPair(selection: [head, branch]),
            BranchDashboardComparisonPair(
                rootPath: "/repo-a",
                first: "feature/login",
                second: "main"
            )
        )
        XCTAssertFalse(availability.contains(.updateSelected))
        XCTAssertFalse(availability.contains(.deleteSelected))
    }

    func testBranchDashboardHeadAndCurrentBranchSelectionDisablesPairComparisons() {
        let head = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: true,
            headBranchName: "main"
        )
        let current = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head, current])

        XCTAssertNil(branchDashboardComparisonPair(selection: [head, current]))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardHeadPairFailsClosedWithoutNamedCurrentBranch() {
        let head = BranchDashboardReference(
            rootPath: "/repo-detached",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: true
        )
        let branch = BranchDashboardReference(
            rootPath: "/repo-detached",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head, branch])

        XCTAssertNil(branchDashboardComparisonPair(selection: [head, branch]))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))

        let unbornHead = BranchDashboardReference(
            rootPath: "/repo-unborn",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false,
            headBranchName: "main"
        )
        let unbornBranch = BranchDashboardReference(
            rootPath: "/repo-unborn",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let unbornAvailability = BranchDashboardActionAvailability.resolve(
            selection: [unbornHead, unbornBranch]
        )

        XCTAssertNil(branchDashboardComparisonPair(selection: [unbornHead, unbornBranch]))
        XCTAssertFalse(unbornAvailability.isEnabled(.compareSelected))
        XCTAssertFalse(unbornAvailability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardTagSelectionUsesReferenceActions() {
        let tag = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [tag])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.merge))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.deleteTag))
        XCTAssertTrue(availability.contains(.pushTag))
        XCTAssertFalse(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.compareWithCurrent))
        XCTAssertFalse(availability.contains(.rename))
        XCTAssertFalse(availability.contains(.deleteSelected))

        let currentTag = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let currentAvailability = BranchDashboardActionAvailability.resolve(selection: [currentTag])

        XCTAssertFalse(currentAvailability.contains(.checkout))
        XCTAssertFalse(currentAvailability.contains(.merge))
        XCTAssertFalse(currentAvailability.contains(.deleteTag))
        XCTAssertTrue(currentAvailability.contains(.pushTag))
        XCTAssertFalse(currentAvailability.contains(.createWorktree))
    }

    func testBranchDashboardTagSelectionDoesNotExposeBranchPairOrBatchBranchActions() {
        let tag = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let branch = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [tag, branch])

        XCTAssertFalse(availability.contains(.compareSelected))
        XCTAssertFalse(availability.contains(.compareSelectedFiles))
        XCTAssertFalse(availability.contains(.deleteSelected))
    }

    func testBranchDashboardMultipleTagSelectionExposesDeleteAction() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "v1.2.4",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.contains(.compareSelected))
        XCTAssertFalse(availability.contains(.updateSelected))
    }

    func testBranchDashboardRemoteGroupSelectionUsesIntellijGroupActions() {
        let group = BranchDashboardRemoteGroup(rootPath: "/repo-a", name: "origin")

        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: [group])

        XCTAssertTrue(availability.contains(.editRemote))
        XCTAssertTrue(availability.contains(.removeRemote))
    }

    func testBranchDashboardMultipleRemoteGroupsOnlyExposeRemove() {
        let groups = [
            BranchDashboardRemoteGroup(rootPath: "/repo-a", name: "origin"),
            BranchDashboardRemoteGroup(rootPath: "/repo-b", name: "upstream")
        ]

        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: groups)

        XCTAssertFalse(availability.contains(.editRemote))
        XCTAssertTrue(availability.contains(.removeRemote))
    }

    func testBranchDashboardEmptyRemoteGroupSelectionHasNoActions() {
        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: [])

        XCTAssertFalse(availability.contains(.editRemote))
        XCTAssertFalse(availability.contains(.removeRemote))
    }

    func testBranchDashboardCurrentLocalDisablesDestructiveAndRevisionSwitchActions() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.filterLog))
        XCTAssertTrue(availability.contains(.push))
        XCTAssertTrue(availability.contains(.setUpstream))
        XCTAssertFalse(availability.contains(.compareWithCurrent))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.checkout))
        XCTAssertFalse(availability.contains(.merge))
        XCTAssertFalse(availability.contains(.rebase))
        XCTAssertTrue(availability.contains(.rename))
        XCTAssertFalse(availability.contains(.deleteLocal))
    }

    func testBranchDashboardOpenWorktreeRequiresLinkedWorktreePath() {
        let linked = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            worktreePath: "/tmp/repo-a-feature"
        )
        let regular = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/regular",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        XCTAssertTrue(
            BranchDashboardActionAvailability.resolve(selection: [linked]).contains(.openWorktree)
        )
        XCTAssertFalse(
            BranchDashboardActionAvailability.resolve(selection: [regular]).contains(.openWorktree)
        )
    }

    func testBranchDashboardUpdateRemainsVisibleButDisabledWithoutTracking() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/untracked",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.update))
        XCTAssertFalse(availability.isEnabled(.update))
        XCTAssertTrue(availability.contains(.checkoutWithUpdate))
        XCTAssertFalse(availability.isEnabled(.checkoutWithUpdate))
    }

    func testBranchDashboardUpdateAndRebaseRemainVisibleButDisabledForLinkedWorktree() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false,
            worktreePath: "/tmp/repo-a-feature"
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.update))
        XCTAssertFalse(availability.isEnabled(.update))
        XCTAssertTrue(availability.contains(.checkoutWithUpdate))
        XCTAssertFalse(availability.isEnabled(.checkoutWithUpdate))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
        XCTAssertFalse(availability.isEnabled(.checkoutWithRebase))
    }

    func testBranchDashboardBatchUpdateDisablesWhenAnyBranchIsInLinkedWorktree() {
        let linked = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false,
            worktreePath: "/tmp/repo-a-feature"
        )
        let regular = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/regular",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(
            selection: [linked, regular]
        )

        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertFalse(availability.isEnabled(.updateSelected))
    }

    func testLinkedWorktreePathSkipsCurrentRootRegardlessOfListOrder() {
        let worktrees = [
            WorktreeInfo(
                path: "/tmp/repo-a-linked",
                headId: "linked",
                branch: "feature/worktree",
                isBare: false,
                locked: false,
                prunable: false
            ),
            WorktreeInfo(
                path: "/tmp/repo-a",
                headId: "main",
                branch: "feature/worktree",
                isBare: false,
                locked: false,
                prunable: false
            )
        ]

        XCTAssertEqual(
            linkedWorktreePathForBranch(
                branch: "feature/worktree",
                worktrees: worktrees,
                currentRootPath: "/tmp/repo-a"
            ),
            "/tmp/repo-a-linked"
        )
    }

    func testBranchDashboardLocalWithoutRemoteKeepsPushButHidesTrackingActions() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/local-only",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.push))
        XCTAssertFalse(availability.contains(.setUpstream))
        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.deleteLocal))
        XCTAssertTrue(availability.contains(.createWorktree))
    }

    func testBranchDashboardLocalReferenceExposesCheckoutVariants() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertTrue(availability.contains(.checkoutWithUpdate))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
    }

    func testBranchDashboardTrackedRemoteReferenceExposesPullVariants() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            localBranchName: "feature/login",
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertFalse(availability.contains(.checkoutWithUpdate))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.pull))
        XCTAssertTrue(availability.contains(.pullWithRebase))
        XCTAssertFalse(availability.contains(.createWorktree))
    }

    func testBranchDashboardProtectedRemoteDeleteIsVisibleButDisabled() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/main",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.fetch))
        XCTAssertTrue(availability.contains(.merge))
        XCTAssertTrue(availability.contains(.rebase))
        XCTAssertTrue(availability.contains(.deleteRemote))
        XCTAssertFalse(availability.isEnabled(.deleteRemote))
    }

    func testBranchDashboardMixedOrCrossRootSelectionUsesSafeActions() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let sameNameOtherRoot = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let remote = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let crossRootAvailability = BranchDashboardActionAvailability.resolve(
            selection: [local, sameNameOtherRoot]
        )
        XCTAssertTrue(crossRootAvailability.contains(.compareSelected))
        XCTAssertTrue(crossRootAvailability.contains(.compareSelectedFiles))
        XCTAssertFalse(crossRootAvailability.isEnabled(.compareSelected))
        XCTAssertFalse(crossRootAvailability.isEnabled(.compareSelectedFiles))
        XCTAssertTrue(crossRootAvailability.contains(.updateSelected))
        XCTAssertTrue(crossRootAvailability.contains(.deleteSelected))
        let mixedAvailability = BranchDashboardActionAvailability.resolve(
            selection: [local, remote]
        )
        XCTAssertTrue(mixedAvailability.contains(.compareSelected))
        XCTAssertTrue(mixedAvailability.contains(.compareSelectedFiles))
        XCTAssertTrue(mixedAvailability.contains(.deleteSelected))
        XCTAssertFalse(mixedAvailability.contains(.updateSelected))
    }

    func testBranchDashboardMultipleLocalSelectionExposesIntellijBatchActions() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/settings",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.contains(.checkout))
        XCTAssertFalse(availability.contains(.merge))
        XCTAssertFalse(availability.contains(.createWorktree))
    }

    func testBranchDashboardMultipleLocalSelectionBlocksDeleteWhenCurrentIsIncluded() {
        let current = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let feature = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [current, feature])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertTrue(availability.isEnabled(.updateSelected))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.isEnabled(.deleteSelected))
    }

    func testBranchDashboardSameBranchSelectionShowsDisabledPairComparisons() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardCrossRootBatchKeepsWritesRootScopedButDisablesCompare() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardMultipleRemoteSelectionExposesCompareAndDelete() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/settings",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertTrue(availability.isEnabled(.deleteSelected))
        XCTAssertFalse(availability.contains(.updateSelected))
    }

    func testSelectedRemoteBranchDeleteGroupsStayRootQualified() {
        let targets = [
            BranchDashboardReference(
                rootPath: "/repo-b",
                name: "origin/release",
                kind: .remote,
                remote: "origin",
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: false
            ),
            BranchDashboardReference(
                rootPath: "/repo-a",
                name: "origin/feature",
                kind: .remote,
                remote: "origin",
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: false
            ),
            BranchDashboardReference(
                rootPath: "/repo-b",
                name: "origin/feature",
                kind: .remote,
                remote: "origin",
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: false
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootRemoteBranchDeleteGroups(targets),
            [
                ContentView.MultiRootRemoteBranchDeleteGroup(
                    remoteBranch: "origin/feature",
                    rootPaths: ["/repo-a", "/repo-b"]
                ),
                ContentView.MultiRootRemoteBranchDeleteGroup(
                    remoteBranch: "origin/release",
                    rootPaths: ["/repo-b"]
                )
            ]
        )
    }

    func testBranchDashboardProtectedRemoteBlocksOnlyBatchDelete() {
        let protected = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/main",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )
        let feature = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(
            selection: [protected, feature]
        )

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.isEnabled(.deleteSelected))
    }

    func testSingleRemoteReferenceKeepsPullVisibleWithoutLocalTrackingAndDisablesProtectedDelete() {
        let remote = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/release",
            kind: .remote,
            remote: "origin",
            localBranchName: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [remote])

        XCTAssertTrue(availability.contains(.pull))
        XCTAssertTrue(availability.contains(.pullWithRebase))
        XCTAssertTrue(availability.contains(.deleteRemote))
        XCTAssertFalse(availability.isEnabled(.deleteRemote))
    }

    func testSingleLocalReferenceDisablesCheckoutActionsForAnotherWorktreeButKeepsRename() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false,
            worktreePath: "/tmp/feature-worktree"
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [local])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertFalse(availability.isEnabled(.checkout))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
        XCTAssertFalse(availability.isEnabled(.checkoutWithRebase))
        XCTAssertTrue(availability.contains(.rename))
    }

    func testBranchTreeSelectionSkipsGroupsAndWraps() {
        let rows = branchDirectoryRows(
            for: ["feature/login", "feature/ui", "main"],
            grouped: true,
            scope: "selection"
        )
        let ids = branchTreeSelectableIDs(rows, collapsedGroups: [])
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(
            movedBranchTreeSelection(currentID: ids[0], selectableIDs: ids, offset: 1),
            ids[1]
        )
        XCTAssertEqual(
            movedBranchTreeSelection(currentID: ids[0], selectableIDs: ids, offset: -1),
            ids[2]
        )
        XCTAssertEqual(
            movedBranchTreeSelection(currentID: ids[0], selectableIDs: ids, offset: -1, wraps: false),
            ids[0]
        )
        XCTAssertEqual(
            branchTreeSelectableIDs(rows, collapsedGroups: [rows[0].id]),
            [ids[2]]
        )
    }

    func testCommandBranchTreeSelectionTogglesWithoutCrossRootCollision() {
        XCTAssertEqual(
            toggledBranchTreeSelection(current: [], id: "multi:/repo-a:local:feature/a", command: false),
            ["multi:/repo-a:local:feature/a"]
        )
        XCTAssertEqual(
            toggledBranchTreeSelection(
                current: ["multi:/repo-a:local:feature/a"],
                id: "multi:/repo-b:local:feature/a",
                command: true
            ),
            [
                "multi:/repo-a:local:feature/a",
                "multi:/repo-b:local:feature/a"
            ]
        )
        XCTAssertEqual(
            toggledBranchTreeSelection(
                current: ["multi:/repo-a:local:feature/a", "multi:/repo-b:local:feature/a"],
                id: "multi:/repo-a:local:feature/a",
                command: true
            ),
            ["multi:/repo-b:local:feature/a"]
        )
    }

    func testShiftBranchTreeSelectionUsesRootQualifiedVisibleOrder() {
        let orderedIDs = [
            "multi:/repo-a:local:feature/a",
            "multi:/repo-a:local:feature/b",
            "multi:/repo-b:local:feature/a",
            "multi:/repo-b:remote:origin/feature/a"
        ]

        let range = branchTreeSelectionAfterClick(
            current: [orderedIDs[0]],
            anchorID: orderedIDs[0],
            orderedIDs: orderedIDs,
            id: orderedIDs[2],
            command: false,
            shift: true
        )
        XCTAssertEqual(range.selection, Set(orderedIDs[0...2]))
        XCTAssertEqual(range.anchorID, orderedIDs[0])

        let extended = branchTreeSelectionAfterClick(
            current: range.selection,
            anchorID: range.anchorID,
            orderedIDs: orderedIDs,
            id: orderedIDs[3],
            command: true,
            shift: true
        )
        XCTAssertEqual(extended.selection, Set(orderedIDs))
        XCTAssertEqual(extended.anchorID, orderedIDs[0])

        let missingAnchor = branchTreeSelectionAfterClick(
            current: [orderedIDs[1]],
            anchorID: "multi:/repo-c:local:missing",
            orderedIDs: orderedIDs,
            id: orderedIDs[2],
            command: false,
            shift: true
        )
        XCTAssertEqual(missingAnchor.selection, Set([orderedIDs[2]]))
        XCTAssertEqual(missingAnchor.anchorID, orderedIDs[2])
    }

    func testHeadBranchTreeSelectionSharesRootQualifiedRangeIdentity() {
        let orderedIDs = [
            "multi:/repo-a:head:HEAD",
            "multi:/repo-a:local:feature/login"
        ]

        let selection = branchTreeSelectionAfterClick(
            current: [orderedIDs[0]],
            anchorID: orderedIDs[0],
            orderedIDs: orderedIDs,
            id: orderedIDs[1],
            command: false,
            shift: true
        )

        XCTAssertEqual(selection.selection, Set(orderedIDs))
        XCTAssertEqual(selection.anchorID, orderedIDs[0])
    }

    func testMultiRootLogRangeSelectionSkipsRemoteGroupTargets() {
        let visibleBranchIDs = [
            "log.multi:/repo-a:head:HEAD",
            "log.multi:/repo-a:local:feature/login",
            "log.multi:/repo-a:remote:origin/feature/login"
        ]
        let remoteGroupID = "log.multi:/repo-a:remote-group:origin"

        let selection = branchTreeSelectionAfterClick(
            current: [visibleBranchIDs[0]],
            anchorID: visibleBranchIDs[0],
            orderedIDs: visibleBranchIDs,
            id: visibleBranchIDs[2],
            command: false,
            shift: true
        )

        XCTAssertEqual(selection.selection, Set(visibleBranchIDs))
        XCTAssertFalse(selection.selection.contains(remoteGroupID))
    }

    func testVisibleBranchNamesFollowTreeOrderAndCollapsedGroups() {
        let names = ["hotfix/one", "feature/ui", "feature/login"]
        let rows = branchDirectoryRows(for: names, grouped: true, scope: "visible")
        let featureGroupID = rows.first(where: { $0.isGroup && $0.name == "feature" })!.id

        XCTAssertEqual(
            visibleBranchDirectoryRefNames(
                names,
                grouped: true,
                scope: "visible",
                collapsedGroups: []
            ),
            ["hotfix/one", "feature/ui", "feature/login"]
        )
        XCTAssertEqual(
            visibleBranchDirectoryRefNames(
                names,
                grouped: true,
                scope: "visible",
                collapsedGroups: [featureGroupID]
            ),
            ["hotfix/one"]
        )
    }
}

final class GitPushSettingsTests: XCTestCase {
    func testForceWithLeaseDefaultsToEnabled() {
        let suite = UserDefaults(suiteName: "Arbor.GitPushSettingsTests.default")!
        suite.removePersistentDomain(forName: "Arbor.GitPushSettingsTests.default")

        XCTAssertTrue(GitPushSettings.forceWithLeaseDefault(from: suite))
    }

    func testForceWithLeaseDefaultCanBeDisabled() {
        let suite = UserDefaults(suiteName: "Arbor.GitPushSettingsTests.disabled")!
        suite.removePersistentDomain(forName: "Arbor.GitPushSettingsTests.disabled")
        suite.set(false, forKey: GitPushSettings.forceWithLeaseDefaultKey)

        XCTAssertFalse(GitPushSettings.forceWithLeaseDefault(from: suite))
    }

    func testForceWithLeaseDecisionPreservesPushSafetyBoundaries() {
        let suite = UserDefaults(suiteName: "Arbor.GitPushSettingsTests.decision")!
        suite.removePersistentDomain(forName: "Arbor.GitPushSettingsTests.decision")

        XCTAssertFalse(GitPushSettings.useForceWithLease(force: false, requested: nil, defaults: suite))
        XCTAssertTrue(GitPushSettings.useForceWithLease(force: true, requested: nil, defaults: suite))
        XCTAssertFalse(GitPushSettings.useForceWithLease(force: true, requested: false, defaults: suite))
    }
}

final class GitLocalChangesSavePolicySettingsTests: XCTestCase {
    func testIntelliJDefaultIsShelf() {
        let suiteName = "Arbor.GitLocalChangesSavePolicyTests.default"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(from: suite),
            .shelve
        )
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.engineValue(from: suite),
            .shelve
        )
    }

    func testConfiguredStashPolicyMapsToEngine() {
        let suiteName = "Arbor.GitLocalChangesSavePolicyTests.stash"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set(GitLocalChangesSavePolicyChoice.stash.rawValue, forKey: GitLocalChangesSavePolicySettings.key)

        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.engineValue(from: suite),
            .stash
        )
    }

    func testInvalidStoredPolicyUsesShelfDefault() {
        let suiteName = "Arbor.GitLocalChangesSavePolicyTests.invalid"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set("invalid", forKey: GitLocalChangesSavePolicySettings.key)

        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(from: suite),
            .shelve
        )
    }
}

final class PushDialogTests: XCTestCase {
    func testOnlyCommitAndPushKeepsNoRemoteCommitFallback() {
        XCTAssertTrue(PushDialogMode.commitAndPush.allowsCommitOnlyFallbackWithoutRemote)
        XCTAssertFalse(PushDialogMode.push.allowsCommitOnlyFallbackWithoutRemote)
        XCTAssertFalse(PushDialogMode.pushUpToCommit.allowsCommitOnlyFallbackWithoutRemote)
        XCTAssertFalse(PushDialogMode.addCommitsToRemoteBranch.allowsCommitOnlyFallbackWithoutRemote)
    }

    func testAddCommitsToRemoteBranchUsesDedicatedPushMode() {
        XCTAssertEqual(
            PushDialogMode.addCommitsToRemoteBranch.title,
            "Add Commits to Remote Branch"
        )
        XCTAssertEqual(
            PushDialogMode.addCommitsToRemoteBranch.actionTitle,
            "Push"
        )
    }

    func testPushTagModesMatchIntelliJOptions() {
        XCTAssertEqual(PushDialogTagMode.all.title, "All tags")
        XCTAssertEqual(
            PushDialogTagMode.currentBranch.title,
            "Tags reachable from current branch"
        )
        XCTAssertEqual(PushDialogTagMode.allCases, [.all, .currentBranch])
    }

    func testPushUpToCommitBuildsDetachedSourceRefspec() {
        XCTAssertEqual(
            PushDialogRefspec.pushUpToCommit(
                sourceRevision: "abc123",
                targetBranch: "release/1.0"
            ),
            "abc123:refs/heads/release/1.0"
        )
    }

    func testPushUpToCommitAcceptsFullTargetRef() {
        XCTAssertEqual(
            PushDialogRefspec.pushUpToCommit(
                sourceRevision: "HEAD~2",
                targetBranch: "refs/heads/release"
            ),
            "HEAD~2:refs/heads/release"
        )
    }

    func testPushUpToCommitRequiresBothSourceAndTarget() {
        XCTAssertNil(
            PushDialogRefspec.pushUpToCommit(sourceRevision: "", targetBranch: "main")
        )
        XCTAssertNil(
            PushDialogRefspec.pushUpToCommit(sourceRevision: "abc123", targetBranch: " ")
        )
    }
}

private final class HostingMockURLProtocol: URLProtocol {
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
