import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let beforeCommitCommandsKey = "arbor.beforeCommitCommands"

/// Git reports several different pinentry/GPG failures for the same user
/// action. Keep the classifier narrow enough that an SSH signing failure does
/// not incorrectly send the user to GPG settings.
func gitCommitSigningFailureNeedsGPGConfiguration(_ message: String) -> Bool {
    let normalized = message.lowercased()
    if normalized.contains("ssh-keygen")
        || normalized.contains("ssh signing")
        || normalized.contains("signing format: ssh") {
        return false
    }
    return normalized.contains("gpg failed to sign")
        || normalized.contains("gpg: signing failed")
        || normalized.contains("gpg: no secret key")
        || normalized.contains("secret key not available")
        || normalized.contains("pinentry")
}

func gnuPGAvailabilityFailure(_ message: String) -> Bool {
    let normalized = message.lowercased()
    if normalized.contains("cannot resolve gnupg home directory") {
        return true
    }
    return normalized.contains("gpgconf")
        && (normalized.contains("cannot start")
            || normalized.contains("not found")
            || normalized.contains("no such file"))
}

enum GnuPGInstallationGuide {
    static let downloadURL = URL(string: "https://gnupg.org/download/")!
}

enum GitCloneSettings {
    static let recurseSubmodulesKey = "arbor.clone.recurse.submodules.v1"
    static let defaultRecurseSubmodules = true

    static func recurseSubmodules(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: recurseSubmodulesKey) != nil else {
            return defaultRecurseSubmodules
        }
        return defaults.bool(forKey: recurseSubmodulesKey)
    }

    static func saveRecurseSubmodules(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: recurseSubmodulesKey)
    }
}

enum GitProtectedBranchRules {
    static let userDefaultsKey = "arbor.git.protectedBranchPatterns.v1"
    static let defaultPatterns = "main\nmaster"
    static let synchronizeKey = "arbor.git.synchronizeBranchProtectionRules.v1"
    static let defaultSynchronize = true
    private static let projectPatternsKeyPrefix = "arbor.git.protectedBranchPatterns.project.v1:"
    private static let projectSynchronizeKeyPrefix = "arbor.git.synchronizeBranchProtectionRules.project.v1:"
    private static let remotePatternsKeyPrefix = "arbor.git.remoteProtectedBranchPatterns.v1:"

    static func patterns(from rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ branch: String, patterns: [String]) -> Bool {
        let normalized = branch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "refs/heads/", with: "")
        guard !normalized.isEmpty else { return false }
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else {
                return false
            }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            return expression.firstMatch(in: normalized, options: [], range: range) != nil
        }
    }

    static func synchronizeRemotePatterns(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: synchronizeKey) != nil else {
            return defaultSynchronize
        }
        return defaults.bool(forKey: synchronizeKey)
    }

    static func synchronizeRemotePatterns(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        projectSynchronizeValue(for: projectPath, defaults: defaults)
            ?? synchronizeRemotePatterns(from: defaults)
    }

    static func globalRawValue(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: userDefaultsKey) ?? defaultPatterns
    }

    private static func projectKey(
        prefix: String,
        for projectPath: String?
    ) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return prefix + data.base64EncodedString()
    }

    static func projectRawValue(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let key = projectKey(prefix: projectPatternsKeyPrefix, for: projectPath) else {
            return nil
        }
        return defaults.string(forKey: key)
    }

    static func saveProjectPatterns(
        _ rawValue: String?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(prefix: projectPatternsKeyPrefix, for: projectPath) else {
            return
        }
        if let rawValue {
            defaults.set(rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func projectSynchronizeValue(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool? {
        guard let key = projectKey(prefix: projectSynchronizeKeyPrefix, for: projectPath),
              defaults.object(forKey: key) != nil else {
            return nil
        }
        return defaults.bool(forKey: key)
    }

    static func saveProjectSynchronize(
        _ value: Bool?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(prefix: projectSynchronizeKeyPrefix, for: projectPath) else {
            return
        }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func remotePatternsKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return remotePatternsKeyPrefix + data.base64EncodedString()
    }

    static func loadRemotePatterns(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> [String] {
        guard let key = remotePatternsKey(for: projectPath),
              let data = defaults.data(forKey: key),
              let patterns = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return patterns
    }

    static func saveRemotePatterns(
        _ patterns: [String],
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = remotePatternsKey(for: projectPath) else {
            return
        }
        var seen = Set<String>()
        let uniquePatterns = patterns.filter { seen.insert($0).inserted }
        guard let data = try? JSONEncoder().encode(uniquePatterns) else { return }
        defaults.set(data, forKey: key)
    }

    static func combinedPatterns(
        localRawValue: String,
        remotePatterns: [String],
        synchronize: Bool
    ) -> [String] {
        let local = patterns(from: localRawValue)
        guard synchronize else { return local }
        var seen = Set<String>()
        return (local + remotePatterns).filter { seen.insert($0).inserted }
    }

    static func remotePatterns(
        forRootPath rootPath: String?,
        primaryPatterns: [String],
        patternsByRoot: [String: [String]]
    ) -> [String] {
        guard let rootPath else { return primaryPatterns }
        let key = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return patternsByRoot[key] ?? []
    }

    static func synchronizedRemotePatterns(
        cachedPatterns: [String],
        fetchedPatterns: Set<String>,
        hasProviderFailure: Bool
    ) -> [String] {
        (hasProviderFailure ? Set(cachedPatterns).union(fetchedPatterns) : fetchedPatterns).sorted()
    }

    /// Converts GitHub's branch-protection mask syntax using the same rules as
    /// IntelliJ's PatternUtil.convertToRegex: '*' and '?' are masks, while
    /// regex metacharacters in literal text are escaped.
    static func githubMaskToRegex(_ mask: String) -> String {
        var result = ""
        for character in mask {
            switch character {
            case "*": result += ".*"
            case "?": result += "."
            case "\\": result += "\\\\"
            case ".", "$", "|", "(", ")", "[", "{", "^", "+", "]", "/", "}":
                result += "\\\(character)"
            default: result.append(character)
            }
        }
        return result
    }
}

enum GitBranchesPopupSettings {
    private static let keyPrefix = "arbor.git.branchesPopup.project.v1:"
    static let showRecentBranchesKey = "showRecentBranches"
    static let filterByActionInPopupKey = "filterByActionInPopup"
    static let filterByRepositoryKey = "filterByRepository"
    static let groupByRepositoryKey = "groupByRepository"
    static let groupByDirectoryKey = "groupByDirectory"
    static let showTagsKey = "showTags"
    static let logSelectionActionKey = "logSelectionAction"
    static let favoriteBranchesKey = "favoriteBranches"
    static let collapsedDirectoryGroupsKey = "collapsedDirectoryGroups"
    static let logCollapsedDirectoryGroupsKey = "logCollapsedDirectoryGroups"

    static let defaultShowRecentBranches = true
    static let defaultFilterByActionInPopup = true
    static let defaultFilterByRepository = true
    static let defaultGroupByRepository = true
    static let defaultGroupByDirectory = true
    static let defaultShowTags = true
    static let defaultLogSelectionAction = "navigate"

    private static func key(
        _ setting: String,
        for projectPath: String?
    ) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return "\(keyPrefix)\(data.base64EncodedString()):\(setting)"
    }

    static func value(
        _ setting: String,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(setting, for: projectPath),
              defaults.object(forKey: key) != nil else {
            return defaultValue(for: setting)
        }
        return defaults.bool(forKey: key)
    }

    static func save(
        _ value: Bool,
        _ setting: String,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(setting, for: projectPath) else { return }
        defaults.set(value, forKey: key)
    }

    static func stringValue(
        _ setting: String,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> String {
        guard let key = key(setting, for: projectPath),
              let value = defaults.string(forKey: key) else {
            return defaultStringValue(for: setting)
        }
        return value
    }

    static func save(
        _ value: String,
        _ setting: String,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(setting, for: projectPath) else { return }
        defaults.set(value, forKey: key)
    }

    static func favorites(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        guard let key = key(favoriteBranchesKey, for: projectPath),
              let stored = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return Set(stored)
    }

    static func saveFavorites(
        _ favorites: Set<String>,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(favoriteBranchesKey, for: projectPath) else { return }
        if favorites.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(favorites.sorted(), forKey: key)
        }
    }

    static func collapsedDirectoryGroups(
        for projectPath: String?,
        setting: String = collapsedDirectoryGroupsKey,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        guard let key = key(setting, for: projectPath),
              let stored = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return Set(stored)
    }

    static func saveCollapsedDirectoryGroups(
        _ groups: Set<String>,
        for projectPath: String?,
        setting: String = collapsedDirectoryGroupsKey,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(setting, for: projectPath) else { return }
        if groups.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(groups.sorted(), forKey: key)
        }
    }

    private static func defaultValue(for setting: String) -> Bool {
        switch setting {
        case showRecentBranchesKey: defaultShowRecentBranches
        case filterByActionInPopupKey: defaultFilterByActionInPopup
        case filterByRepositoryKey: defaultFilterByRepository
        case groupByRepositoryKey: defaultGroupByRepository
        case groupByDirectoryKey: defaultGroupByDirectory
        default: true
        }
    }

    private static func defaultStringValue(for setting: String) -> String {
        switch setting {
        case logSelectionActionKey: defaultLogSelectionAction
        default: ""
        }
    }
}

/// Persists IntelliJ's project-level Compare Branches side preference. The
/// default presentation keeps the current working tree on the left, while a
/// user can swap it so the selected branch becomes the left side.
enum GitCompareBranchesSettings {
    static let defaultSwapSides = false
    private static let projectKeyPrefix = "arbor.git.compareBranches.swapSides.project.v1:"

    static func swapSides(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = projectKey(for: projectPath),
              defaults.object(forKey: key) != nil else {
            return defaultSwapSides
        }
        return defaults.bool(forKey: key)
    }

    static func saveSwapSides(
        _ enabled: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        defaults.set(enabled, forKey: key)
    }

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return projectKeyPrefix + data.base64EncodedString()
    }
}

enum GitExecutableSettings {
    static let applicationKey = "arbor.git.executable"
    private static let projectKeyPrefix = "arbor.git.executable.project.v1:"

    private static func projectKey(for projectPath: String) -> String {
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(projectKeyPrefix)\(data.base64EncodedString())"
    }

    static func projectOverride(
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let value = defaults.string(forKey: projectKey(for: projectPath))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func saveProjectOverride(
        _ path: String?,
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) {
        let key = projectKey(for: projectPath)
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(path, forKey: key)
    }

    static func registeredRoots(
        projectPath: String,
        repositoryRoot: String?,
        discoveredRoots: [String]
    ) -> [String] {
        var paths = [projectPath]
        if let repositoryRoot, !repositoryRoot.isEmpty {
            paths.append(repositoryRoot)
        }
        paths.append(contentsOf: discoveredRoots)
        return Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
    }
}

enum GitPushSettings {
    static let forceWithLeaseDefaultKey = "arbor.git.push.forceWithLeaseDefault.v1"
    static let defaultForceWithLease = true

    static func forceWithLeaseDefault(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: forceWithLeaseDefaultKey) != nil else {
            return defaultForceWithLease
        }
        return defaults.bool(forKey: forceWithLeaseDefaultKey)
    }

    static func useForceWithLease(
        force: Bool,
        requested: Bool?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        force && (requested ?? forceWithLeaseDefault(from: defaults))
    }
}

enum GitPushAutoUpdateSettings {
    static let defaultAutoUpdateIfRejected = false
    private static let projectKeyPrefix = "arbor.git.pushAutoUpdate.project.v1:"

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func value(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = projectKey(for: projectPath),
              defaults.object(forKey: key) != nil else {
            return defaultAutoUpdateIfRejected
        }
        return defaults.bool(forKey: key)
    }

    static func save(
        _ enabled: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        defaults.set(enabled, forKey: key)
    }
}

enum GitSignOffCommitSettings {
    static let defaultSignOff = false
    static let globalKey = "arbor.git.signOffCommit.v1"
    private static let legacyGlobalKey = "arbor.identity.signOff"
    private static let projectKeyPrefix = "arbor.git.signOffCommit.project.v1:"

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func projectValue(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool? {
        guard let key = projectKey(for: projectPath),
              defaults.object(forKey: key) != nil else {
            return nil
        }
        return defaults.bool(forKey: key)
    }

    static func globalValue(from defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: globalKey) != nil {
            return defaults.bool(forKey: globalKey)
        }
        if defaults.object(forKey: legacyGlobalKey) != nil {
            return defaults.bool(forKey: legacyGlobalKey)
        }
        return defaultSignOff
    }

    static func value(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        projectValue(for: projectPath, defaults: defaults) ?? globalValue(from: defaults)
    }

    static func saveProjectValue(
        _ enabled: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        defaults.set(enabled, forKey: key)
    }

    static func saveGlobal(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: globalKey)
    }
}

enum GitResetModeChoice: String, CaseIterable, Identifiable, Sendable {
    case soft
    case mixed
    case hard
    case keep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: return "Soft"
        case .mixed: return "Mixed"
        case .hard: return "Hard"
        case .keep: return "Keep"
        }
    }

    var detail: String {
        switch self {
        case .soft: return "Move HEAD and keep the index and working tree unchanged."
        case .mixed: return "Reset the index while keeping working-tree files unchanged."
        case .hard: return "Reset the index and working tree; uncommitted changes may be discarded."
        case .keep: return "Keep non-overlapping local changes and reject overlapping ones."
        }
    }

    var engineValue: ResetMode {
        switch self {
        case .soft: return .soft
        case .mixed: return .mixed
        case .hard: return .hard
        case .keep: return .keep
        }
    }

    init(_ mode: ResetMode) {
        switch mode {
        case .soft: self = .soft
        case .mixed: self = .mixed
        case .hard: self = .hard
        case .keep: self = .keep
        }
    }
}

enum GitResetModeSettings {
    static let defaultMode = GitResetModeChoice.mixed
    private static let projectKeyPrefix = "arbor.git.resetMode.project.v1:"

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func mode(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitResetModeChoice {
        guard let key = projectKey(for: projectPath),
              let rawValue = defaults.string(forKey: key),
              let mode = GitResetModeChoice(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    static func save(
        _ mode: GitResetModeChoice,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        defaults.set(mode.rawValue, forKey: key)
    }
}

enum GitCommitWarningSetting: String, CaseIterable, Identifiable, Sendable {
    case crlf
    case detachedHead
    case largeFile
    case badFileName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crlf: return "Mixed line endings (CRLF/LF)"
        case .detachedHead: return "Detached HEAD"
        case .largeFile: return "Large staged files"
        case .badFileName: return "Windows-incompatible file names"
        }
    }
}

enum GitCommitWarningSettings {
    static let defaultLargeFileLimitMB = 50
    private static let projectKeyPrefix = "arbor.git.commitWarning.project.v1:"

    private static func key(
        _ setting: GitCommitWarningSetting,
        for projectPath: String?
    ) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(projectKeyPrefix)\(data.base64EncodedString()):\(setting.rawValue)"
    }

    private static func limitKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(projectKeyPrefix)\(data.base64EncodedString()):largeFileLimitMB"
    }

    static func warningEnabled(
        _ setting: GitCommitWarningSetting,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(setting, for: projectPath),
              defaults.object(forKey: key) != nil else {
            return true
        }
        return defaults.bool(forKey: key)
    }

    static func saveWarning(
        _ enabled: Bool,
        _ setting: GitCommitWarningSetting,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(setting, for: projectPath) else { return }
        defaults.set(enabled, forKey: key)
    }

    static func largeFileLimitMB(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard let key = limitKey(for: projectPath),
              defaults.object(forKey: key) != nil else {
            return defaultLargeFileLimitMB
        }
        return max(1, defaults.integer(forKey: key))
    }

    static func largeFileLimitBytes(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> UInt64 {
        UInt64(largeFileLimitMB(for: projectPath, defaults: defaults)) * 1024 * 1024
    }

    static func saveLargeFileLimitMB(
        _ limitMB: Int,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = limitKey(for: projectPath) else { return }
        defaults.set(max(1, limitMB), forKey: key)
    }
}

/// Persists IntelliJ's missing-identity choice per project. The default is
/// global because Git's identity is normally a user-level setting; users can
/// opt into repository-local values from the identity sheet.
enum GitIdentityScopeSettings {
    static let defaultSetNameEmailGlobally = true
    private static let keyPrefix = "arbor.git.identityScope.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(keyPrefix)\(data.base64EncodedString()):setNameEmailGlobally"
    }

    static func setNameEmailGlobally(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(for: projectPath),
              defaults.object(forKey: key) != nil else {
            return defaultSetNameEmailGlobally
        }
        return defaults.bool(forKey: key)
    }

    static func saveSetNameEmailGlobally(
        _ enabled: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        defaults.set(enabled, forKey: key)
    }
}

/// Project-scoped equivalent of IntelliJ's PREVIOUS_COMMIT_AUTHORS list.
/// Entries use Git's familiar `Name <email>` form and are kept in MRU order.
enum GitCommitAuthorHistorySettings {
    static let limit = 16
    private static let keyPrefix = "arbor.git.commitAuthors.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(keyPrefix)\(data.base64EncodedString())"
    }

    static func authors(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> [String] {
        guard let key = key(for: projectPath) else { return [] }
        let values = (defaults.array(forKey: key) as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(values.prefix(limit))
    }

    static func save(
        _ author: String,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        let normalized = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var values = authors(for: projectPath, defaults: defaults)
        values.removeAll { $0 == normalized }
        values.insert(normalized, at: 0)
        defaults.set(Array(values.prefix(limit)), forKey: key)
    }

    static func formattedAuthor(name: String, email: String) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !normalizedEmail.isEmpty else { return nil }
        return "\(normalizedName) <\(normalizedEmail)>"
    }

    static func parse(_ author: String) -> (name: String, email: String)? {
        let value = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix(">"),
              let separator = value.lastIndex(of: "<") else {
            return nil
        }
        let name = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let emailStart = value.index(after: separator)
        let emailEnd = value.index(before: value.endIndex)
        let email = value[emailStart..<emailEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return nil }
        return (String(name), String(email))
    }
}

func gitPushAutoUpdateIsEligible(
    enabled: Bool,
    force: Bool,
    refspec: String?,
    currentBranch: String?,
    rejectedBranch: String,
    hasTracking: Bool
) -> Bool {
    guard enabled,
          !force,
          refspec == nil,
          currentBranch == rejectedBranch,
          hasTracking else {
        return false
    }
    return true
}

/// Controls the post-commit Push executor, matching IntelliJ's
/// `shouldPreviewPushOnCommitAndPush` and `previewPushProtectedOnly` settings.
/// Preview remains the safe default; automatic Push is opt-in and still
/// refuses to bypass missing remotes or a detached HEAD.
enum GitPushAfterCommitPreviewChoice: String, CaseIterable, Identifiable, Sendable {
    case always
    case protectedOnly
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always preview before pushing"
        case .protectedOnly: "Preview protected branches only"
        case .automatic: "Push automatically"
        }
    }

    var detail: String {
        switch self {
        case .always:
            "Open Push options after a successful Commit and Push commit."
        case .protectedOnly:
            "Push ordinary branches directly; show Push options for protected branches or roots that cannot be pushed automatically."
        case .automatic:
            "Push ordinary branches directly after the commit. Missing remotes and detached roots still open the Push flow."
        }
    }
}

enum GitPushAfterCommitSettings {
    static let globalKey = "arbor.git.push.afterCommitPreview.v1"
    static let projectKeyPrefix = "arbor.git.push.afterCommitPreview.project.v1:"
    static let defaultChoice = GitPushAfterCommitPreviewChoice.always

    static func choice(from defaults: UserDefaults = .standard) -> GitPushAfterCommitPreviewChoice {
        guard let raw = defaults.string(forKey: globalKey),
              let choice = GitPushAfterCommitPreviewChoice(rawValue: raw) else {
            return defaultChoice
        }
        return choice
    }

    static func projectChoice(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitPushAfterCommitPreviewChoice? {
        guard let key = projectKey(for: projectPath),
              let raw = defaults.string(forKey: key) else {
            return nil
        }
        return GitPushAfterCommitPreviewChoice(rawValue: raw)
    }

    static func choice(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitPushAfterCommitPreviewChoice {
        projectChoice(for: projectPath, defaults: defaults) ?? choice(from: defaults)
    }

    static func saveProjectChoice(
        _ choice: GitPushAfterCommitPreviewChoice?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        if let choice {
            defaults.set(choice.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let encoded = Data(normalized.utf8).base64EncodedString()
        return projectKeyPrefix + encoded
    }
}

enum GitCherryPickEmptyPolicyChoice: String, CaseIterable, Identifiable {
    case skip
    case createEmpty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skip: "Skip empty cherry-picks"
        case .createEmpty: "Create empty commits"
        }
    }

    var engineValue: CherryPickEmptyPolicy {
        switch self {
        case .skip: .skip
        case .createEmpty: .createEmpty
        }
    }
}

enum GitDeleteOnMergeOption: String, CaseIterable, Identifiable, Sendable {
    case delete
    case propose
    case nothing

    static let key = "arbor.git.merge.deleteOnMerge.v1"
    static let defaultOption = GitDeleteOnMergeOption.propose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .delete: "Delete merged local branch"
        case .propose: "Propose deleting merged local branch"
        case .nothing: "Do nothing"
        }
    }

    var detail: String {
        switch self {
        case .delete:
            "After a successful merge, delete the eligible local source branch automatically."
        case .propose:
            "After a successful merge, offer a one-click action to delete the eligible local source branch."
        case .nothing:
            "Keep the source branch after a successful merge."
        }
    }

    static func choice(from defaults: UserDefaults = .standard) -> GitDeleteOnMergeOption {
        guard let raw = defaults.string(forKey: key),
              let option = GitDeleteOnMergeOption(rawValue: raw) else {
            return defaultOption
        }
        return option
    }

    static func effectiveOption(
        _ configured: GitDeleteOnMergeOption,
        canDeleteBranch: Bool
    ) -> GitDeleteOnMergeOption {
        canDeleteBranch ? configured : .nothing
    }
}

enum GitLocalChangesSavePolicyChoice: String, CaseIterable, Identifiable {
    case stash
    case shelve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stash: "Stash"
        case .shelve: "Shelf"
        }
    }

    var detail: String {
        switch self {
        case .stash: "Use Git's stash stack and restore the index with --index."
        case .shelve: "Use Arbor's persistent Shelf model; the default IntelliJ behavior."
        }
    }

    var engineValue: LocalChangesSavePolicy {
        switch self {
        case .stash: .stash
        case .shelve: .shelve
        }
    }
}

enum GitLocalChangesSavePolicySettings {
    static let key = "arbor.git.localChangesSavePolicy.v1"
    static let defaultPolicy = GitLocalChangesSavePolicyChoice.shelve

    static func choice(from defaults: UserDefaults = .standard) -> GitLocalChangesSavePolicyChoice {
        guard let raw = defaults.string(forKey: key),
              let choice = GitLocalChangesSavePolicyChoice(rawValue: raw) else {
            return defaultPolicy
        }
        return choice
    }

    static func engineValue(from defaults: UserDefaults = .standard) -> LocalChangesSavePolicy {
        choice(from: defaults).engineValue
    }

    static func choice(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitLocalChangesSavePolicyChoice {
        GitProjectLocalChangesSavePolicySettings.choice(
            for: projectPath,
            defaults: defaults
        ) ?? choice(from: defaults)
    }

    static func engineValue(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> LocalChangesSavePolicy {
        choice(for: projectPath, defaults: defaults).engineValue
    }
}

/// Project-scoped equivalent of IntelliJ's GitVcsSettings.saveChangesPolicy.
/// A missing override deliberately falls back to the application setting so
/// existing projects keep their current behavior until they opt in.
enum GitProjectLocalChangesSavePolicySettings {
    private static let keyPrefix = "arbor.git.localChangesSavePolicy.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return keyPrefix + data.base64EncodedString()
    }

    static func choice(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitLocalChangesSavePolicyChoice? {
        guard let key = key(for: projectPath),
              let raw = defaults.string(forKey: key) else {
            return nil
        }
        return GitLocalChangesSavePolicyChoice(rawValue: raw)
    }

    static func save(
        _ choice: GitLocalChangesSavePolicyChoice?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        if let choice {
            defaults.set(choice.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

struct GitLocalChangesSavePolicySettingsSection: View {
    @AppStorage(GitLocalChangesSavePolicySettings.key)
    private var policy = GitLocalChangesSavePolicySettings.defaultPolicy.rawValue

    var body: some View {
        Section("Local Changes Preservation") {
            Picker("Save local changes as", selection: $policy) {
                ForEach(GitLocalChangesSavePolicyChoice.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            if let choice = GitLocalChangesSavePolicyChoice(rawValue: policy) {
                Text(choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Used before Pull, Update Project, Rebase, and smart checkout operations. An interrupted restore remains recoverable after restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum GitDropCommitSettings {
    static let showConfirmationKey = "arbor.git.dropCommit.showConfirmation.v1"
    static let defaultShowConfirmation = true

    static func showConfirmation(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showConfirmationKey) != nil else {
            return defaultShowConfirmation
        }
        return defaults.bool(forKey: showConfirmationKey)
    }
}

struct GitDropCommitSettingsSection: View {
    @AppStorage(GitDropCommitSettings.showConfirmationKey)
    private var showConfirmation = GitDropCommitSettings.defaultShowConfirmation

    var body: some View {
        Section("History Rewrite") {
            Toggle("Confirm Drop Commits", isOn: $showConfirmation)
            Text("When disabled, linear Drop Commit actions execute immediately after their safety checks. Root, merge, protected, and non-current-history commits remain unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum GitChangelistSettings {
    static let createAutomaticallyKey = "arbor.git.changelists.createAutomatically.v1"
    static let defaultCreateAutomatically = false

    static func createAutomatically(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: createAutomaticallyKey) != nil else {
            return defaultCreateAutomatically
        }
        return defaults.bool(forKey: createAutomaticallyKey)
    }
}

struct GitChangelistSettingsSection: View {
    @AppStorage(GitChangelistSettings.createAutomaticallyKey)
    private var createAutomatically = GitChangelistSettings.defaultCreateAutomatically

    var body: some View {
        Section("Changelists") {
            Toggle("Create Changelists automatically", isOn: $createAutomatically)
            Text("When enabled, an Unshelve without an explicit target creates or reuses a Changelist named after the Shelf description. IntelliJ keeps this option off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum GitCherryPickSettings {
    static let emptyPolicyKey = "arbor.git.cherryPick.emptyPolicy.v1"
    static let appendPublishedSuffixKey = "arbor.git.cherryPick.appendPublishedSuffix.v1"
    static let defaultEmptyPolicy = GitCherryPickEmptyPolicyChoice.skip
    static let defaultAppendPublishedSuffix = true

    private static let projectAppendPublishedSuffixKeyPrefix = "arbor.git.cherryPick.appendPublishedSuffix.project.v1:"

    private static func projectAppendPublishedSuffixKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectAppendPublishedSuffixKeyPrefix + data.base64EncodedString()
    }

    static func appendPublishedSuffix(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: appendPublishedSuffixKey) != nil else {
            return defaultAppendPublishedSuffix
        }
        return defaults.bool(forKey: appendPublishedSuffixKey)
    }

    static func projectAppendPublishedSuffix(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool? {
        guard let key = projectAppendPublishedSuffixKey(for: projectPath),
              defaults.object(forKey: key) != nil else {
            return nil
        }
        return defaults.bool(forKey: key)
    }

    static func effectiveAppendPublishedSuffix(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        projectAppendPublishedSuffix(for: projectPath, defaults: defaults)
            ?? appendPublishedSuffix(from: defaults)
    }

    static func saveProjectAppendPublishedSuffix(
        _ value: Bool?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectAppendPublishedSuffixKey(for: projectPath) else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

struct GitCherryPickSettingsSection: View {
    @AppStorage(GitCherryPickSettings.emptyPolicyKey)
    private var emptyPolicy = GitCherryPickSettings.defaultEmptyPolicy.rawValue
    @AppStorage(GitCherryPickSettings.appendPublishedSuffixKey)
    private var appendPublishedSuffix = GitCherryPickSettings.defaultAppendPublishedSuffix

    var body: some View {
        Section("Cherry-pick") {
            Picker("When the result is empty", selection: $emptyPolicy) {
                ForEach(GitCherryPickEmptyPolicyChoice.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            Toggle("Add published-commit suffix", isOn: $appendPublishedSuffix)
            Text("Empty cherry-picks are skipped by default. When enabled, cherry-picks of commits already reachable from a protected remote branch append the standard Git origin trailer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum GitPushTagSettings {
    private static let projectKeyPrefix = "arbor.git.pushTags.project.v1:"

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func hasProjectOverride(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = projectKey(for: projectPath) else { return false }
        return defaults.object(forKey: key) != nil
    }

    static func projectTagMode(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> PushDialogTagMode? {
        guard let key = projectKey(for: projectPath),
              let rawValue = defaults.string(forKey: key) else {
            return nil
        }
        return PushDialogTagMode(rawValue: rawValue)
    }

    static func saveProjectTagMode(
        _ mode: PushDialogTagMode?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        if let mode {
            defaults.set(mode.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

struct GitMergeSettingsSection: View {
    @AppStorage(GitDeleteOnMergeOption.key)
    private var deleteOnMerge = GitDeleteOnMergeOption.defaultOption.rawValue

    var body: some View {
        Section("Merge") {
            Picker("After merging a local branch", selection: $deleteOnMerge) {
                ForEach(GitDeleteOnMergeOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            if let option = GitDeleteOnMergeOption(rawValue: deleteOnMerge) {
                Text(option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("This applies only to a non-current local source branch that is not protected. Remote branches, protected branches, and revision-only merges are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

func loadBeforeCommitCommands() -> [BeforeCommitCommand] {
    guard let data = UserDefaults.standard.data(forKey: beforeCommitCommandsKey),
          let commands = try? JSONDecoder().decode([BeforeCommitCommand].self, from: data) else {
        return []
    }
    return commands
}

func saveBeforeCommitCommands(_ commands: [BeforeCommitCommand]) {
    guard let data = try? JSONEncoder().encode(commands) else { return }
    UserDefaults.standard.set(data, forKey: beforeCommitCommandsKey)
}

struct BeforeCommitSettingsView: View {
    @Binding var commands: [BeforeCommitCommand]
    let onIdentity: () -> Void
    @State private var command = ""
    @State private var arguments = ""

    init(commands: Binding<[BeforeCommitCommand]>, onIdentity: @escaping () -> Void = {}) {
        self._commands = commands
        self.onIdentity = onIdentity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before Commit Checks")
                .font(.title3)
                .bold()
            Text("Enter one argument per line. Commands run as argv without a shell.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                TextField("Command, e.g. cargo", text: $command)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $arguments)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 180, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                Button("Add", action: addCommand)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(commands) { item in
                    HStack {
                        Text(item.display)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button("Delete") { commands.removeAll { $0.id == item.id } }
                    }
                }
                .onMove { commands.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            HStack {
                Button("Commit identity & signing", action: onIdentity)
                Spacer()
                Button("Done") { saveBeforeCommitCommands(commands) }
            }
        }
        .padding(16)
        .frame(width: 620, height: 380)
        .onDisappear { saveBeforeCommitCommands(commands) }
    }

    private func addCommand() {
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let args = arguments.split(separator: "\n", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        commands.append(BeforeCommitCommand(command: name, args: args))
        command = ""
        arguments = ""
    }
}

struct GitIdentitySettingsView: View {
    @Binding var name: String
    @Binding var email: String
    @Binding var setNameEmailGlobally: Bool
    @Binding var signingKey: String
    @Binding var signingFormat: String
    @Binding var signCommits: Bool
    @Binding var authorName: String
    @Binding var authorEmail: String
    @Binding var committerName: String
    @Binding var committerEmail: String
    @Binding var signOff: Bool
    @Binding var coAuthors: String
    let recentAuthors: [String]
    let onSelectRecentAuthor: (String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onGpgAgent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git Commit Identity")
                .font(.title3)
                .bold()
            TextField("Author / committer name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
            Toggle("Set user.name and user.email globally", isOn: $setNameEmailGlobally)
                .toggleStyle(.checkbox)
            Text("When enabled, the identity applies to all Git repositories unless a repository has its own local override.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Signing format", selection: $signingFormat) {
                Text("GPG").tag("gpg")
                Text("SSH").tag("ssh")
            }
            .pickerStyle(.segmented)
            TextField("Signing key / SSH public key (optional)", text: $signingKey)
                .textFieldStyle(.roundedBorder)
            Toggle("Sign commits by default", isOn: $signCommits)
                .toggleStyle(.checkbox)
            Divider()
            HStack {
                Text("One-shot author / committer overrides")
                    .font(.headline)
                Spacer()
                if !recentAuthors.isEmpty {
                    Menu("Recent authors") {
                        ForEach(recentAuthors, id: \.self) { author in
                            Button(author) { onSelectRecentAuthor(author) }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Author name", text: $authorName).textFieldStyle(.roundedBorder)
                TextField("Author email", text: $authorEmail).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                TextField("Committer name", text: $committerName).textFieldStyle(.roundedBorder)
                TextField("Committer email", text: $committerEmail).textFieldStyle(.roundedBorder)
            }
            Toggle("Add Signed-off-by", isOn: $signOff)
                .toggleStyle(.checkbox)
            Text("Co-authors (one `Name <email>` per line)")
                .font(.headline)
            TextEditor(text: $coAuthors)
                .font(.system(.body, design: .monospaced))
                .frame(height: 58)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
            Text("Name and email use the selected global or repository-local Git config scope. Signing settings are stored in this repository's local Git config. The author/committer and co-author fields apply to the next commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Configure GPG Agent…", action: onGpgAgent)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// The embedded helper is a small launcher plus the Arbor executable's
/// `--arbor-pinentry` mode. The launcher selects the helper for an Arbor
/// pinentry session and forwards remote-development entrypoints; all other
/// GPG callers use the detected system pinentry.
enum ArborEmbeddedPinentry {
    static let remoteEntrypointPrefix = "IJ_PINENTRY_ENTRYPOINT="

    static var launcherURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupport
            .appendingPathComponent("Arbor", isDirectory: true)
            .appendingPathComponent("gpg-pinentry-launcher")
    }

    static func isConfigured(_ path: String?) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == launcherURL.standardizedFileURL.path
    }

    static func configure() throws -> GpgAgentStatus {
        let current = try gpgAgentStatus()
        let launcherPath = launcherURL.standardizedFileURL.path
        let launcher = try installLauncher(
            fallbackPath: [current.pinentryProgram, current.defaultPinentryProgram]
                .compactMap { $0 }
                .first { path in
                    URL(fileURLWithPath: path).standardizedFileURL.path
                        != launcherPath
                }
        )
        return try configureGpgAgent(pinentryProgram: launcher.path)
    }

    private static func installLauncher(fallbackPath: String?) throws -> URL {
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            throw NSError(
                domain: "Arbor.GPGPinentry",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Arbor executable path is unavailable."]
            )
        }

        let launcher = launcherURL
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = launcherScript(executable: executable, fallbackPath: fallbackPath)
        try Data(script.utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: launcher.path
        )
        return launcher
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launcherScript(executable: String, fallbackPath: String?) -> String {
        var script = "#!/bin/sh\nset -u\n"
        if let fallbackPath, !fallbackPath.isEmpty {
            script += "case \"${PINENTRY_USER_DATA-}\" in\n"
            script += "  \(ArborPinentryEndpoint.prefix)*)\n"
            script += "    exec \(shellQuote(executable)) \(shellQuote(ArborPinentryProcess.argument)) \"$@\"\n"
            script += "    ;;\n"
            script += "  \(remoteEntrypointPrefix)*)\n"
            script += "    entrypoint=\"${PINENTRY_USER_DATA#\(remoteEntrypointPrefix)}\"\n"
            script += "    entrypoint=\"${entrypoint%%:*}\"\n"
            script += "    if [ -n \"$entrypoint\" ]; then exec \"$entrypoint\" \"$@\"; fi\n"
            script += "    ;;\n"
            script += "esac\n"
            script += "exec \(shellQuote(fallbackPath)) \"$@\"\n"
        } else {
            script += "case \"${PINENTRY_USER_DATA-}\" in\n"
            script += "  \(ArborPinentryEndpoint.prefix)*)\n"
            script += "    exec \(shellQuote(executable)) \(shellQuote(ArborPinentryProcess.argument)) \"$@\"\n"
            script += "    ;;\n"
            script += "  \(remoteEntrypointPrefix)*)\n"
            script += "    entrypoint=\"${PINENTRY_USER_DATA#\(remoteEntrypointPrefix)}\"\n"
            script += "    entrypoint=\"${entrypoint%%:*}\"\n"
            script += "    if [ -n \"$entrypoint\" ]; then exec \"$entrypoint\" \"$@\"; fi\n"
            script += "    ;;\n"
            script += "esac\n"
            script += "exec \(shellQuote(executable)) \(shellQuote(ArborPinentryProcess.argument)) \"$@\"\n"
        }
        return script
    }
}

/// External pinentry configuration for GPG agent. The engine owns the
/// gpg-agent.conf backup/atomic-write/reload protocol; this view exposes both
/// the embedded IntelliJ-style helper and the system pinentry fallback.
struct GpgAgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status: GpgAgentStatus?
    @State private var pinentryPath = ""
    @State private var message = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GPG Agent / Pinentry")
                .font(.title3.weight(.semibold))
            Text("Arbor uses the system GPG agent. Configure an external pinentry program, back up the existing agent config, and reload the agent before retrying a signed commit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let status {
                GroupBox("Detected configuration") {
                    VStack(alignment: .leading, spacing: 6) {
                        gpgPathRow("GnuPG home", status.home)
                        gpgPathRow("Agent config", status.configPath)
                        gpgPathRow(
                            "Current pinentry",
                            ArborEmbeddedPinentry.isConfigured(status.pinentryProgram)
                                ? "Arbor embedded"
                                : (status.pinentryProgram ?? "Not configured")
                        )
                        gpgPathRow("Detected default", status.defaultPinentryProgram ?? "Not detected")
                    }
                }
                if !status.available {
                    HStack(alignment: .top, spacing: 8) {
                        Label(
                            "GnuPG is not available. Install GnuPG, then refresh this panel before configuring pinentry.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("GnuPG Downloads") {
                            NSWorkspace.shared.open(GnuPGInstallationGuide.downloadURL)
                        }
                    }
                }
            } else if !message.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    if gnuPGAvailabilityFailure(message)
                        || gitCommitSigningFailureNeedsGPGConfiguration(message) {
                        Button("GnuPG Downloads") {
                            NSWorkspace.shared.open(GnuPGInstallationGuide.downloadURL)
                        }
                    }
                }
            }

            TextField("External pinentry program (optional: use detected default)", text: $pinentryPath)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Choose…", action: choosePinentry)
                Button("Use Detected Default", action: useDetectedDefault)
                    .disabled(status?.defaultPinentryProgram == nil)
                Button("Use Arbor Embedded", action: configureEmbedded)
                    .disabled(isBusy || status?.available == false)
                Spacer()
                Button("Refresh", action: loadStatus)
                    .disabled(isBusy)
                Button("Configure & Reload", action: configure)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || status?.available == false)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Arbor Embedded is selected only for Arbor signing sessions; other GPG callers continue to use the detected system pinentry. Use the system option when GnuPG is managed externally.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: { dismiss() })
            }
        }
        .padding(20)
        .frame(width: 700)
        .onAppear(perform: loadStatus)
    }

    private func gpgPathRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func choosePinentry() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            pinentryPath = url.path
            message = ""
        }
    }

    private func useDetectedDefault() {
        pinentryPath = status?.defaultPinentryProgram ?? ""
        message = ""
    }

    private func loadStatus() {
        isBusy = true
        message = ""
        Task.detached(priority: .userInitiated) {
            do {
                let detected = try gpgAgentStatus()
                await MainActor.run {
                    status = detected
                    if pinentryPath.isEmpty {
                        pinentryPath = detected.pinentryProgram ?? detected.defaultPinentryProgram ?? ""
                    }
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    status = nil
                    message = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }

    private func configure() {
        let selected = pinentryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        message = ""
        Task.detached(priority: .userInitiated) {
            do {
                let updated = try configureGpgAgent(pinentryProgram: selected.isEmpty ? nil : selected)
                await MainActor.run {
                    status = updated
                    pinentryPath = updated.pinentryProgram ?? selected
                    message = "GPG agent configured and reloaded."
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }

    private func configureEmbedded() {
        isBusy = true
        message = ""
        Task.detached(priority: .userInitiated) {
            do {
                let updated = try ArborEmbeddedPinentry.configure()
                await MainActor.run {
                    status = updated
                    pinentryPath = updated.pinentryProgram ?? ArborEmbeddedPinentry.launcherURL.path
                    message = "Arbor embedded pinentry configured and reloaded."
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }
}

struct GitProtectedBranchesSettingsSection: View {
    @AppStorage(GitProtectedBranchRules.userDefaultsKey)
    private var patterns = GitProtectedBranchRules.defaultPatterns

    var body: some View {
        Section("Protected Branches") {
            TextEditor(text: $patterns)
                .font(.system(.body, design: .monospaced))
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
            Text("One regular expression per line. Force push is blocked for matching branches; main and master are protected by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if patterns.split(whereSeparator: \.isNewline).contains(where: {
                (try? NSRegularExpression(pattern: String($0))) == nil
            }) {
                Label("One or more protected branch patterns are invalid.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct ProjectGitProtectedBranchesSettingsSection: View {
    @Binding var patterns: String
    @Binding var synchronize: Bool

    var body: some View {
        Section("Protected Branches") {
            TextEditor(text: $patterns)
                .font(.system(.body, design: .monospaced))
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
            Text("One regular expression per line. Force push is blocked for matching branches; main and master are protected by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if patterns.split(whereSeparator: \.isNewline).contains(where: {
                (try? NSRegularExpression(pattern: String($0))) == nil
            }) {
                Label("One or more protected branch patterns are invalid.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Synchronize hosted protected branch rules after fetch", isOn: $synchronize)
            Text("Hosted rules are added to this project's protected patterns after a successful fetch. Cached rules remain active if synchronization fails.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct GitProtectedBranchSyncSettingsSection: View {
    @AppStorage(GitProtectedBranchRules.synchronizeKey)
    private var synchronize = GitProtectedBranchRules.defaultSynchronize

    var body: some View {
        Section("Remote Protection") {
            Toggle("Synchronize hosted protected branch rules after fetch", isOn: $synchronize)
            Text("Hosted rules are added to the local protected patterns after a successful fetch. Cached rules remain active if synchronization fails.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct GitPushSettingsSection: View {
    @AppStorage(GitPushSettings.forceWithLeaseDefaultKey)
    private var forceWithLeaseDefault = GitPushSettings.defaultForceWithLease
    @AppStorage(GitPushAfterCommitSettings.globalKey)
    private var pushAfterCommitPreview = GitPushAfterCommitSettings.defaultChoice.rawValue

    var body: some View {
        Section("Push") {
            Toggle("Use force-with-lease by default", isOn: $forceWithLeaseDefault)
            Text("When force push is selected, protect against overwriting a remote update unless you explicitly turn lease off in the Push dialog.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("After Commit and Push", selection: $pushAfterCommitPreview) {
                ForEach(GitPushAfterCommitPreviewChoice.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            if let choice = GitPushAfterCommitPreviewChoice(rawValue: pushAfterCommitPreview) {
                Text(choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("A project-specific choice can override this application default in Project Git Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Application-level Git executable selection, matching IntelliJ's
/// GitExecutableManager boundary. The selected path is validated before it is
/// persisted and is used by every system-Git command in the Rust engine.
struct GitExecutableSettingsSection: View {
    @AppStorage(GitExecutableSettings.applicationKey) private var savedPath = ""
    @State private var path = ""
    @State private var version = ""
    @State private var message = ""
    @State private var isBusy = false

    var body: some View {
        Section("Git Executable") {
            Text("Select the Git executable used by Arbor's system Git operations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Path to Git executable", text: $path)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…", action: chooseExecutable)
            }
            HStack(spacing: 8) {
                Button("Test Git executable", action: testExecutable)
                    .disabled(isBusy)
                Button("Save Git executable", action: saveExecutable)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                Button("Reset to PATH default", action: resetExecutable)
                    .disabled(isBusy)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !version.isEmpty {
                Text("Current version: \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !message.isEmpty {
                Label(message, systemImage: version.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(version.isEmpty ? .orange : .green)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            path = gitExecutable()
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            message = ""
            version = ""
        }
    }

    private func testExecutable() {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        message = ""
        version = ""
        Task.detached(priority: .userInitiated) {
            do {
                let result = try testGitExecutable(path: candidate)
                await MainActor.run {
                    self.version = result
                    self.message = "Git executable is valid"
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.message = "Git executable test failed: \(error)"
                    self.isBusy = false
                }
            }
        }
    }

    private func saveExecutable() {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        message = ""
        version = ""
        Task.detached(priority: .userInitiated) {
            do {
                let selected = try setGitExecutable(path: candidate)
                let result = try gitExecutableVersion()
                await MainActor.run {
                    self.path = selected
                    self.savedPath = selected == "git" ? "" : selected
                    self.version = result
                    self.message = "Git executable saved"
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.message = "Git executable save failed: \(error)"
                    self.isBusy = false
                }
            }
        }
    }

    private func resetExecutable() {
        path = ""
        saveExecutable()
    }
}

struct GitSSHSettingsView: View {
    @Binding var command: String
    @Binding var knownHostsFile: String
    @Binding var identityFile: String
    @Binding var hostKeyPolicy: SshHostKeyPolicy
    @Binding var authMethod: SshAuthMethod
    @Binding var credentialHelperConfig: String
    let credentialHelpers: [CredentialHelperInfo]
    let onRefreshCredentialHelpers: () -> Void
    let sshAgentDiagnostics: SshAgentDiagnostics?
    let onRefreshSSHAgentDiagnostics: () -> Void
    let lastSuccessfulAuthentications: [SSHAuthenticationRecord]
    let onClearLastSuccessfulAuthentications: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git SSH Command")
                .font(.title3)
                .bold()
            TextField("e.g. ssh -i ~/.ssh/id_ed25519", text: $command)
                .textFieldStyle(.roundedBorder)
            Text("Stored as this repository's core.sshCommand. Leave it empty to use the default SSH configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The value may include SSH options, such as -i, -F, or -o.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Host key verification")
                .font(.headline)
            Picker("Host key verification", selection: $hostKeyPolicy) {
                Text("Strict (recommended)").tag(SshHostKeyPolicy.strict)
                Text("Accept new keys").tag(SshHostKeyPolicy.acceptNew)
                Text("Ask before trusting").tag(SshHostKeyPolicy.ask)
                Text("Do not verify (unsafe)").tag(SshHostKeyPolicy.noCheck)
            }
            .pickerStyle(.segmented)
            Text("Strict rejects unknown or changed host keys; Ask before trusting shows the host fingerprint; Accept new keys records a first-seen key; Do not verify disables host-key protection.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hostKeyPolicy == .noCheck {
                Label("Host-key verification is disabled for this repository.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                TextField("Known hosts file (optional)", text: $knownHostsFile)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { chooseFile { knownHostsFile = $0 } }
            }
            Picker("Authentication method", selection: $authMethod) {
                Text("Automatic").tag(SshAuthMethod.auto)
                Text("SSH key only").tag(SshAuthMethod.publicKey)
                Text("Password / keyboard-interactive").tag(SshAuthMethod.password)
            }
            Text("Automatic uses the OpenSSH default order. SSH key only restricts authentication to public keys; password mode enables password and keyboard-interactive prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Identity file (optional)", text: $identityFile)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { chooseFile { identityFile = $0 } }
            }
            Text("An identity file enables IdentitiesOnly so OpenSSH does not try unrelated agent keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("SSH agent")
                    .font(.headline)
                Spacer()
                Button("Refresh", action: onRefreshSSHAgentDiagnostics)
                    .controlSize(.small)
            }
            if let diagnostics = sshAgentDiagnostics {
                HStack(spacing: 7) {
                    Image(systemName: diagnostics.state.systemImage)
                        .foregroundStyle(diagnostics.state.tint)
                    Text(diagnostics.state.displayTitle)
                    Spacer()
                    if diagnostics.identityCount > 0 {
                        Text("\(diagnostics.identityCount) identities")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !diagnostics.socketPath.isEmpty {
                    Text("Socket: \(diagnostics.socketPath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("SSH agent diagnostics are not loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Refresh runs the read-only ssh-add -l probe. It never adds, removes, unlocks, or stores agent keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Local credential.helper values")
                .font(.headline)
            Text("One helper per line. These values are stored in this repository's local Git config; leave empty to remove local overrides.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $credentialHelperConfig)
                .font(.system(.body, design: .monospaced))
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack {
                Text("Credential Helpers")
                    .font(.headline)
                Spacer()
                Button("Refresh", action: onRefreshCredentialHelpers)
                    .controlSize(.small)
            }
            if credentialHelpers.isEmpty {
                Text("No repository or user credential helpers are configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(credentialHelpers.enumerated()), id: \.offset) { _, helper in
                    HStack(spacing: 7) {
                        Image(systemName: helper.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(helper.available ? .green : .orange)
                        Text(helper.name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(helper.available ? "Available" : "Not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("The diagnostic list includes repository and user helpers. Available means the executable is present; actual credential success is confirmed only by a successful Git operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Last successful SSH authentications")
                    .font(.headline)
                Spacer()
                Button("Clear", action: onClearLastSuccessfulAuthentications)
                    .controlSize(.small)
                    .disabled(lastSuccessfulAuthentications.isEmpty)
            }
            if lastSuccessfulAuthentications.isEmpty {
                Text("No prompt-based SSH authentication has succeeded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lastSuccessfulAuthentications) { record in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text(record.key)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(record.method == "publickey" ? "SSH key" : "Password")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Only the user@host and method are stored; credentials and SSH agent secrets are never saved here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseFile(_ onSelect: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
    }
}

/// Repository-scoped mergetool selectors. The actual tool command remains
/// owned by Git (`mergetool.<name>.cmd`); Arbor only edits which configured
/// tool Git should select for conflict resolution.
struct GitMergeToolSettingsView: View {
    let repo: Repository
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var mergeTool = ""
    @State private var mergeGUITool = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git External Merge Tool")
                .font(.title3)
                .bold()
            Text("Choose the tool names Git uses for merge conflicts. Configure each command with Git's mergetool.<name>.cmd settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Merge tool name", text: $mergeTool)
                .textFieldStyle(.roundedBorder)
            TextField("GUI merge tool name (optional)", text: $mergeGUITool)
                .textFieldStyle(.roundedBorder)
            Text("These are repository-local overrides. Empty fields remove the local override and let system or global Git configuration apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(isBusy ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { load() }
    }

    private func load() {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            do {
                let settings = try repo.externalMergeToolSettings()
                await MainActor.run {
                    mergeTool = settings.mergeTool
                    mergeGUITool = settings.mergeGuiTool
                    errorMessage = nil
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Unable to read Git mergetool settings: \(error)"
                    isBusy = false
                }
            }
        }
    }

    private func save() {
        isBusy = true
        errorMessage = nil
        let mergeTool = mergeTool.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeGUITool = mergeGUITool.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .userInitiated) {
            do {
                try repo.setExternalMergeToolSettings(
                    mergeTool: mergeTool,
                    mergeGuiTool: mergeGUITool
                )
                await MainActor.run {
                    isBusy = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = "Unable to save Git mergetool settings: \(error)"
                }
            }
        }
    }
}

private extension SshAgentState {
    var displayTitle: String {
        switch self {
        case .notConfigured:
            return String(localized: "SSH agent is not configured")
        case .unreachable:
            return String(localized: "SSH agent is not reachable")
        case .noIdentities:
            return String(localized: "SSH agent is reachable, but has no identities")
        case .ready:
            return String(localized: "SSH agent is ready")
        case .error:
            return String(localized: "SSH agent probe failed")
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .noIdentities:
            return "minus.circle.fill"
        case .notConfigured:
            return "questionmark.circle"
        case .unreachable, .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            return .green
        case .noIdentities, .notConfigured:
            return .secondary
        case .unreachable, .error:
            return .orange
        }
    }
}
