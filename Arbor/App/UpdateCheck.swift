import Foundation

/// One published GitHub release worth telling the user about.
struct AppUpdateInfo: Equatable {
    let version: String
    let releaseURL: URL
}

enum AppUpdateCheckOutcome: Equatable {
    /// The automatic check was suppressed (disabled or ran recently).
    case skipped
    case upToDate(current: String)
    case updateAvailable(AppUpdateInfo, current: String)
    case failed(reason: String)
}

/// Version-string comparison for release tags. Numeric segments win over
/// lexicographic order, a leading "v" is ignored, and inputs with no parseable
/// segments never compare as newer.
func appUpdateCompareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = appUpdateVersionSegments(lhs)
    let right = appUpdateVersionSegments(rhs)
    guard !left.isEmpty, !right.isEmpty else { return .orderedSame }
    let longest = max(left.count, right.count)
    for index in 0..<longest {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        if l < r { return .orderedAscending }
        if l > r { return .orderedDescending }
    }
    return .orderedSame
}

/// "v1.0.21-beta.2" -> [1, 0, 21]; the first non-numeric character ends a
/// segment, and segments without digits are dropped entirely.
private func appUpdateVersionSegments(_ version: String) -> [Int] {
    version
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .drop { $0.lowercased() == "v" }
        .split(separator: ".")
        .compactMap { segment in
            let digits = segment.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
}

private let appUpdateFallbackReleaseURL = URL(
    string: "https://github.com/arixbit/Arbor/releases/latest"
)!

/// Parses the `releases/latest` payload. Anything without a usable tag is
/// treated as "no update information" rather than an error the user sees.
func appUpdateParseLatestRelease(_ data: Data) -> AppUpdateInfo? {
    guard
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tag = payload["tag_name"] as? String,
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    var releaseURL = appUpdateFallbackReleaseURL
    if let htmlURLString = payload["html_url"] as? String,
       let htmlURL = URL(string: htmlURLString),
       htmlURL.scheme == "https" {
        releaseURL = htmlURL
    }
    return AppUpdateInfo(version: version, releaseURL: releaseURL)
}

/// Automatic checks run at most once per interval so a long-lived window does
/// not poll GitHub on every appearance.
func appUpdateShouldAutoCheck(
    lastCheck: Date?,
    now: Date = Date(),
    interval: TimeInterval = 24 * 60 * 60
) -> Bool {
    guard let lastCheck else { return true }
    return now.timeIntervalSince(lastCheck) >= interval
}

/// In-app update check against GitHub Releases. Read-only HTTPS GET; no user
/// data is attached, and failures are silent for the automatic path.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    static let autoCheckDefaultsKey = "arbor.autoCheckForUpdates"
    static let lastCheckDefaultsKey = "arbor.updateCheck.lastCheckDate"
    static let releasesAPI = URL(string: "https://api.github.com/repos/arixbit/Arbor/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/arixbit/Arbor/releases/latest")!

    /// Read through one helper so the toggle default (enabled) lives in
    /// exactly one place; the settings view binds to the same key.
    static var autoCheckEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoCheckDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: autoCheckDefaultsKey)
    }

    static func setAutoCheckEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoCheckDefaultsKey)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Hosted XCTest launches must never touch the network: the unit-test
    /// bundle imports this module directly, and Bundle.main there is the test
    /// runner rather than the app.
    static var isRunningUnderTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    @Published private(set) var isChecking = false
    private var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastCheckDefaultsKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastCheckDefaultsKey) }
    }

    /// True when an automatic check should run right now (toggle on and
    /// outside the 24h window). Called before any network work.
    func autoCheckDue(now: Date = Date()) -> Bool {
        Self.autoCheckEnabled && appUpdateShouldAutoCheck(lastCheck: lastCheckDate, now: now)
    }

    func autoCheckIfNeeded(completion: @escaping (AppUpdateCheckOutcome) -> Void) {
        guard autoCheckDue() else {
            completion(.skipped)
            return
        }
        checkNow(completion: completion)
    }

    func checkNow(completion: @escaping (AppUpdateCheckOutcome) -> Void) {
        guard !isChecking else {
            completion(.skipped)
            return
        }
        isChecking = true
        lastCheckDate = Date()
        DiagnosticsLogger.shared.record(operation: "update-check", code: "started")
        var request = URLRequest(url: Self.releasesAPI)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let outcome: AppUpdateCheckOutcome
            if let error {
                outcome = .failed(reason: error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome = .failed(reason: "HTTP \(http.statusCode)")
            } else if let data,
                      let info = appUpdateParseLatestRelease(data) {
                let current = Self.currentVersion
                if appUpdateCompareVersions(info.version, current) == .orderedDescending {
                    outcome = .updateAvailable(info, current: current)
                } else {
                    outcome = .upToDate(current: current)
                }
            } else {
                outcome = .failed(reason: "unexpected response payload")
            }
            DispatchQueue.main.async {
                self?.isChecking = false
                switch outcome {
                case .updateAvailable(let info, _):
                    DiagnosticsLogger.shared.record(
                        operation: "update-check",
                        code: "update-available-\(info.version)"
                    )
                case .upToDate:
                    DiagnosticsLogger.shared.record(operation: "update-check", code: "up-to-date")
                case .failed:
                    DiagnosticsLogger.shared.record(operation: "update-check", code: "failed")
                case .skipped:
                    break
                }
                completion(outcome)
            }
        }.resume()
    }
}

extension Notification.Name {
    static let arborCheckForUpdates = Notification.Name("arbor.checkForUpdates")
}
