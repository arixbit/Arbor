import SwiftUI
import AppKit
import UniformTypeIdentifiers


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

    // 弹窗尺寸：对应 IntelliJ 分支弹窗的可拖拽 resize + `Git.Branches.Popup.Resize`
    // （Restore Size）。单 root 与多 root 弹窗默认尺寸不同，分开存。

    static let popupWidthKey = "popupWidth"
    static let popupHeightKey = "popupHeight"
    static let multiRootPopupWidthKey = "multiRootPopupWidth"
    static let multiRootPopupHeightKey = "multiRootPopupHeight"

    static let defaultPopupSize = CGSize(width: 350, height: 560)
    static let defaultMultiRootPopupSize = CGSize(width: 700, height: 560)

    static func popupSize(
        for projectPath: String?,
        multiRoot: Bool = false,
        defaults: UserDefaults = .standard
    ) -> CGSize {
        let fallback = multiRoot ? defaultMultiRootPopupSize : defaultPopupSize
        let widthSetting = multiRoot ? multiRootPopupWidthKey : popupWidthKey
        let heightSetting = multiRoot ? multiRootPopupHeightKey : popupHeightKey
        guard let widthKey = key(widthSetting, for: projectPath),
              let heightKey = key(heightSetting, for: projectPath),
              defaults.object(forKey: widthKey) != nil,
              defaults.object(forKey: heightKey) != nil else {
            return fallback
        }
        return CGSize(
            width: CGFloat(defaults.double(forKey: widthKey)),
            height: CGFloat(defaults.double(forKey: heightKey))
        )
    }

    static func savePopupSize(
        _ size: CGSize,
        multiRoot: Bool = false,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        let widthSetting = multiRoot ? multiRootPopupWidthKey : popupWidthKey
        let heightSetting = multiRoot ? multiRootPopupHeightKey : popupHeightKey
        guard let widthKey = key(widthSetting, for: projectPath),
              let heightKey = key(heightSetting, for: projectPath) else { return }
        defaults.set(Double(size.width), forKey: widthKey)
        defaults.set(Double(size.height), forKey: heightKey)
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
