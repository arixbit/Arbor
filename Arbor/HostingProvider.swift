import Foundation

enum HostingProviderKind: String, Codable, Hashable, Sendable {
    case github
    case gitlab
    case bitbucket
}

/// Mirrors IntelliJ's hosted-reference action group presentation: no
/// supported remote hides the action, one remote executes directly, and
/// multiple supported remotes become a selectable submenu.
enum HostedRemoteActionPresentation: Equatable {
    case hidden
    case direct
    case submenu
}

func hostedRemoteActionPresentation(for remoteCount: Int) -> HostedRemoteActionPresentation {
    switch remoteCount {
    case 1:
        return .direct
    case 2...:
        return .submenu
    default:
        return .hidden
    }
}

/// Resolve a remote only when the caller explicitly selected it or there is
/// exactly one configured remote. Multiple remotes must never fall through to
/// array order, which would silently publish to the wrong repository.
func resolveSelectedRemoteName(
    selectedRemote: String?,
    availableRemoteNames: [String]
) -> String? {
    if let selectedRemote {
        return availableRemoteNames.contains(selectedRemote) ? selectedRemote : nil
    }
    guard availableRemoteNames.count == 1 else { return nil }
    return availableRemoteNames[0]
}

/// Match IntelliJ's default remote used by Fetch/Unshallow: a single remote
/// is unambiguous; with several remotes prefer the current branch's valid
/// tracked remote, then `origin`, and otherwise require an explicit choice.
func defaultFetchRemoteName(
    preferredRemote: String?,
    availableRemoteNames: [String]
) -> String? {
    guard !availableRemoteNames.isEmpty else { return nil }
    if availableRemoteNames.count == 1 {
        return availableRemoteNames[0]
    }
    if let preferredRemote,
       availableRemoteNames.contains(preferredRemote) {
        return preferredRemote
    }
    return availableRemoteNames.contains("origin") ? "origin" : nil
}

/// A repository address understood by a hosting API client.
struct HostingRepository: Hashable, Sendable {
    let provider: HostingProviderKind
    let owner: String
    let name: String
    let projectPath: String
    let host: String
    let webBaseURL: URL
    let apiBaseURL: URL

    var fullName: String { "\(owner)/\(name)" }

    var webURL: URL {
        webBaseURL.appendingPathComponent(projectPath)
    }

    func pullRequestsURL() -> URL {
        switch provider {
        case .github:
            return webURL.appendingPathComponent("pulls")
        case .gitlab:
            return webURL
                .appendingPathComponent("-")
                .appendingPathComponent("merge_requests")
        case .bitbucket:
            return webURL.appendingPathComponent("pull-requests")
        }
    }

    func issuesURL() -> URL {
        webURL.appendingPathComponent("issues")
    }

    func pullRequestURL(number: Int) -> URL {
        pullRequestsURL().appendingPathComponent(String(number))
    }
}

enum HostingProvider {
    /// Parses HTTPS, SSH and SCP-style git remotes.
    ///
    /// GitHub Enterprise hosts do not have a fixed hostname convention. Pass
    /// `enterpriseAPIBaseURL` for an explicitly configured enterprise host.
    static func parse(
        remoteURL: String,
        enterpriseAPIBaseURL: URL? = nil
    ) -> HostingRepository? {
        guard let parts = remoteParts(remoteURL) else { return nil }
        let host = parts.host.lowercased()
        let isGitHubHost = host == "github.com" || host.hasSuffix(".github.com")
        let isGitLabHost = host == "gitlab.com"
        let isBitbucketHost = host == "bitbucket.org"
        guard isGitHubHost || isGitLabHost || isBitbucketHost || enterpriseAPIBaseURL != nil else { return nil }

        let webBase: URL
        let apiBase: URL
        let provider: HostingProviderKind
        if host == "github.com" {
            provider = .github
            webBase = URL(string: "https://github.com")!
            apiBase = enterpriseAPIBaseURL ?? URL(string: "https://api.github.com")!
        } else if isGitLabHost {
            provider = .gitlab
            webBase = URL(string: "https://gitlab.com")!
            apiBase = URL(string: "https://gitlab.com/api/v4")!
        } else if isBitbucketHost {
            provider = .bitbucket
            webBase = URL(string: "https://bitbucket.org")!
            apiBase = URL(string: "https://api.bitbucket.org/2.0")!
        } else {
            provider = .github
            webBase = URL(string: "https://\(parts.host)")!
            apiBase = enterpriseAPIBaseURL
                ?? URL(string: "https://\(parts.host)/api/v3")!
        }

        return HostingRepository(
            provider: provider,
            owner: parts.owner,
            name: parts.name,
            projectPath: parts.projectPath,
            host: parts.host,
            webBaseURL: webBase,
            apiBaseURL: apiBase
        )
    }

    private static func remoteParts(_ value: String) -> (host: String, owner: String, name: String, projectPath: String)? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasSuffix(".git") {
            raw.removeLast(4)
        }

        let host: String
        let path: String
        if raw.hasPrefix("git@"), let colon = raw.firstIndex(of: ":") {
            let hostStart = raw.index(raw.startIndex, offsetBy: 4)
            host = String(raw[hostStart..<colon])
            path = String(raw[raw.index(after: colon)...])
        } else if let url = URL(string: raw), let urlHost = url.host {
            host = urlHost
            path = url.path
        } else if let slash = raw.firstIndex(of: "/") {
            host = String(raw[..<slash])
            path = String(raw[slash...])
        } else {
            return nil
        }

        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2,
              !components[0].isEmpty,
              !components[1].isEmpty else { return nil }
        return (host, components[0], components.last!, components.joined(separator: "/"))
    }
}
