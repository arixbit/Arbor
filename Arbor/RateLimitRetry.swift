import Foundation

// MARK: - Provider-neutral hosting client

enum HostingAPIError: Error, LocalizedError, Equatable, Sendable {
    case missingToken(provider: HostingProviderKind, owner: String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, message: String)
    case invalidResponse
    case transport(message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken(let provider, _):
            return String(localized: "No token is configured for \(provider.rawValue).")
        case .unauthorized:
            return String(localized: "Hosting provider authentication failed.")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return String(localized: "Hosting API rate limit exceeded. Retry after \(Int(ceil(retryAfter))) seconds.")
            }
            return String(localized: "Hosting API rate limit exceeded.")
        case .http(let status, let message):
            return "Hosting API (\(status): \(message))"
        case .invalidResponse:
            return String(localized: "Hosting provider returned an invalid response.")
        case .transport(let message):
            return message
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .missingToken, .unauthorized: true
        case .http(let status, _): status == 401 || status == 403
        default: false
        }
    }
}
final class HostingRateLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRemaining: Int?
    private var storedResetDate: Date?

    var remaining: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedRemaining
    }

    var resetDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedResetDate
    }

    fileprivate func record(_ response: HTTPURLResponse) {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            .flatMap(Int.init)
        let resetDate = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        guard remaining != nil || resetDate != nil else { return }
        lock.lock()
        storedRemaining = remaining
        storedResetDate = resetDate
        lock.unlock()
    }
}

/// Shared HTTP behavior for the provider-specific clients.
///
/// The retry policy intentionally only retries rate-limit responses. It does
/// not retry ordinary 4xx/5xx responses, so authentication and server errors
/// remain visible to the caller instead of being hidden behind extra traffic.
struct HostingHTTPTransport {
    let session: URLSession
    let maxAttempts: Int
    let rateLimit: HostingRateLimit?
    /// Test-only seam; production callers use the server-provided delay.
    let retryDelayOverride: TimeInterval?

    init(
        session: URLSession = .shared,
        maxAttempts: Int = 3,
        retryDelayOverride: TimeInterval? = nil,
        rateLimit: HostingRateLimit? = nil
    ) {
        self.session = session
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayOverride = retryDelayOverride
        self.rateLimit = rateLimit
    }

    func request<Response: Decodable>(
        baseURL: URL,
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        headers: [String: String] = [:],
        bodyData: Data? = nil
    ) async throws -> Response {
        guard let baseRequestURL = makeURL(baseURL: baseURL, path: path) else {
            throw HostingAPIError.invalidResponse
        }

        var url = baseRequestURL
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            guard let queryURL = components?.url else {
                throw HostingAPIError.invalidResponse
            }
            url = queryURL
        }

        for attempt in 0..<maxAttempts {
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if let bodyData {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = bodyData
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HostingAPIError.invalidResponse
                }
                rateLimit?.record(http)

                if (200..<300).contains(http.statusCode) {
                    do {
                        return try JSONDecoder().decode(Response.self, from: data)
                    } catch {
                        throw HostingAPIError.transport(message: error.localizedDescription)
                    }
                }

                let retryAfter = retryDelay(for: http)
                if isRateLimited(http), attempt + 1 < maxAttempts {
                    try await sleep(for: retryAfter)
                    continue
                }
                if isRateLimited(http) {
                    throw HostingAPIError.rateLimited(retryAfter: retryAfter)
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw HostingAPIError.unauthorized
                }
                throw HostingAPIError.http(
                    status: http.statusCode,
                    message: responseMessage(data: data, statusCode: http.statusCode)
                )
            } catch let error as HostingAPIError {
                throw error
            } catch {
                throw HostingAPIError.transport(message: error.localizedDescription)
            }
        }

        throw HostingAPIError.rateLimited(retryAfter: nil)
    }

    private func makeURL(baseURL: URL, path: String) -> URL? {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: base + relative)
    }

    private func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 429 { return true }
        return response.statusCode == 403
            && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    }

    private func retryDelay(for response: HTTPURLResponse) -> TimeInterval {
        if let retryDelayOverride { return max(0, retryDelayOverride) }
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(0, seconds), 60)
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let epoch = TimeInterval(reset) {
            return min(max(0, epoch - Date().timeIntervalSince1970), 60)
        }
        return 1
    }

    private func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(min(seconds, 60) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func responseMessage(data: Data, statusCode: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
            if let errors = object["errors"] {
                return String(describing: errors)
            }
        }
        return HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }
}
