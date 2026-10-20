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
            let query = Dictionary(uniqueKeysWithValues:
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map {
                    ($0.name, $0.value ?? "")
                } ?? []
            )
            XCTAssertEqual(query["state"], "opened")
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
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/api/v4/projects/acme/arbor/merge_requests/7")
                return (response, Data("""
                {"iid":7,"diff_refs":{"base_sha":"base","start_sha":"start","head_sha":"head"}}
                """.utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v4/projects/acme/arbor/merge_requests/7/discussions")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["body"] as? String, "Please rename this.")
            let position = try XCTUnwrap(json["position"] as? [String: Any])
            XCTAssertEqual(position["new_path"] as? String, "Sources/App.swift")
            XCTAssertEqual(position["new_line"] as? Int, 12)
            XCTAssertEqual(position["base_sha"] as? String, "base")
            XCTAssertEqual(position["start_sha"] as? String, "start")
            XCTAssertEqual(position["head_sha"] as? String, "head")
            return (response, Data("""
            {"notes":[{"id":99,"body":"Please rename this.","position":{"new_path":"Sources/App.swift","new_line":12,"head_sha":"head"}}]}
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

    func testGitLabApproveAndMergeBindMutationToExpectedHeadRevision() async throws {
        let repository = try XCTUnwrap(
            HostingProvider.parse(remoteURL: "https://gitlab.com/acme/arbor.git")
        )
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        try store.setToken("gitlab-token", for: repository)
        defer { try? store.deleteToken(for: repository) }

        HostingMockURLProtocol.requestHandler = { request in
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            switch request.url?.path {
            case "/api/v4/projects/acme/arbor/merge_requests/7/approve":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(json["sha"] as? String, "reviewed-head")
                return (response, Data("{}".utf8))
            case "/api/v4/projects/acme/arbor/merge_requests/7/merge":
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(json["sha"] as? String, "reviewed-head")
                XCTAssertEqual(json["squash"] as? Bool, true)
                return (response, Data("{\"iid\":7,\"state\":\"merged\"}".utf8))
            default:
                throw NSError(domain: "HostingProviderTests", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected GitLab mutation path \(request.url?.path ?? "nil")"
                ])
            }
        }

        let client = GitLabClient(session: makeHostingMockSession(), keychain: store)
        try await client.submitGitLabReview(
            for: repository,
            iid: 7,
            outcome: .approve,
            body: nil,
            expectedHeadRevision: "reviewed-head"
        )
        try await client.mergeGitLabMergeRequest(
            for: repository,
            iid: 7,
            method: "squash",
            expectedHeadRevision: "reviewed-head"
        )
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
