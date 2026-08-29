import Foundation

// MARK: - GitHub device authorization

enum GitHubOAuthError: Error, LocalizedError, Equatable, Sendable {
    case missingClientID
    case invalidResponse
    case authorizationDenied
    case authorizationExpired
    case server(message: String)
    case transport(message: String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return String(localized: "Configure a GitHub OAuth client ID before starting device authorization.")
        case .invalidResponse:
            return String(localized: "GitHub returned an invalid device authorization response.")
        case .authorizationDenied:
            return String(localized: "GitHub authorization was denied.")
        case .authorizationExpired:
            return String(localized: "GitHub device authorization expired. Start again.")
        case .server(let message), .transport(let message):
            return message
        }
    }
}

struct GitHubDeviceAuthorization: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: Int
    let interval: Int
}

struct GitHubOAuthFlow {
    let session: URLSession
    let keychain: KeychainStore
    let clientID: String
    let scope: String
    let deviceCodeURL: URL
    let accessTokenURL: URL
    /// Test seam; production uses GitHub's interval response.
    let sleepOverride: TimeInterval?

    init(
        clientID: String,
        scope: String = "repo read:user",
        session: URLSession = .shared,
        keychain: KeychainStore = .shared,
        deviceCodeURL: URL = URL(string: "https://github.com/login/device/code")!,
        accessTokenURL: URL = URL(string: "https://github.com/login/oauth/access_token")!,
        sleepOverride: TimeInterval? = nil
    ) {
        self.session = session
        self.keychain = keychain
        self.clientID = clientID
        self.scope = scope
        self.deviceCodeURL = deviceCodeURL
        self.accessTokenURL = accessTokenURL
        self.sleepOverride = sleepOverride
    }

    func startDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubOAuthError.missingClientID
        }
        let response: GitHubDeviceCodeResponse = try await postForm(
            url: deviceCodeURL,
            fields: ["client_id": clientID, "scope": scope]
        )
        guard let deviceCode = response.deviceCode,
              let userCode = response.userCode,
              let verification = response.verificationURI,
              let verificationURL = URL(string: verification),
              let expiresIn = response.expiresIn else {
            throw GitHubOAuthError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresIn: expiresIn,
            interval: response.interval ?? 5
        )
    }

    func authorizeAndStoreToken(
        for repository: HostingRepository,
        authorization: GitHubDeviceAuthorization
    ) async throws -> String {
        var interval = TimeInterval(max(0, authorization.interval))
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, authorization.expiresIn)))

        while Date() < deadline {
            let response: GitHubAccessTokenResponse = try await postForm(
                url: accessTokenURL,
                fields: [
                    "client_id": clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            if let accessToken = response.accessToken, !accessToken.isEmpty {
                do {
                    try keychain.setToken(accessToken, for: repository)
                } catch {
                    throw GitHubOAuthError.transport(message: error.localizedDescription)
                }
                return accessToken
            }

            switch response.error {
            case "authorization_pending":
                try await sleep(for: interval)
            case "slow_down":
                interval += 5
                try await sleep(for: interval)
            case "access_denied":
                throw GitHubOAuthError.authorizationDenied
            case "expired_token":
                throw GitHubOAuthError.authorizationExpired
            case .some(let error):
                throw GitHubOAuthError.server(message: response.errorDescription ?? error)
            case nil:
                throw GitHubOAuthError.invalidResponse
            }
        }

        throw GitHubOAuthError.authorizationExpired
    }

    private func postForm<Response: Decodable>(
        url: URL,
        fields: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData(fields)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubOAuthError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(GitHubOAuthErrorResponse.self, from: data).errorDescription)
                    ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                throw GitHubOAuthError.server(message: message)
            }
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw GitHubOAuthError.transport(message: error.localizedDescription)
            }
        } catch let error as GitHubOAuthError {
            throw error
        } catch {
            throw GitHubOAuthError.transport(message: error.localizedDescription)
        }
    }

    private func sleep(for seconds: TimeInterval) async throws {
        let actual = max(0, sleepOverride ?? seconds)
        guard actual > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(actual * 1_000_000_000))
    }

    private func formData(_ fields: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return form.data(using: .utf8)
    }
}

private struct GitHubDeviceCodeResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct GitHubAccessTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubOAuthErrorResponse: Decodable {
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case errorDescription = "error_description"
    }
}
