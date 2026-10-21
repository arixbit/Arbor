import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers


/// Project-scoped equivalent of IntelliJ's DvcsSyncSettings. The undecided
/// state preserves the reference default; Arbor keeps explicit root-qualified
/// selection available even when synchronized actions are enabled.
enum GitRootSyncChoice: String, CaseIterable, Identifiable, Sendable {
    case notDecided = "not-decided"
    case sync
    case dontSync = "dont-sync"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .notDecided: "Automatic (not decided)"
        case .sync: "Execute branch operations on all roots"
        case .dontSync: "Use the selected repository only"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .notDecided:
            "Keep Arbor's explicit root-qualified selection until a project policy is chosen."
        case .sync:
            "Same-name branch actions may target every matching Git root in the project."
        case .dontSync:
            "Branch-row actions stay scoped to their owning Git root; explicit multi-selection remains available."
        }
    }

    var shouldExecuteOperationsOnAllRoots: Bool {
        self != .dontSync
    }
}

enum GitRootSyncSettings {
    private static let projectKeyPrefix = "arbor.git.rootSync.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }

    static func choice(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitRootSyncChoice {
        guard let key = key(for: projectPath),
              let raw = defaults.string(forKey: key),
              let choice = GitRootSyncChoice(rawValue: raw) else {
            return .notDecided
        }
        return choice
    }

    static func save(
        _ choice: GitRootSyncChoice,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        if choice == .notDecided {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(choice.rawValue, forKey: key)
        }
    }
}

/// Project-level equivalent of IntelliJ's GitFetchTagsMode setting.
enum GitFetchTagsModeChoice: String, CaseIterable, Identifiable, Sendable {
    case `default` = "default"
    case pruneTags = "prune-tags"
    case allTags = "all-tags"
    case noTags = "no-tags"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .default: "Git default"
        case .pruneTags: "Fetch and prune tags"
        case .allTags: "Fetch all tags"
        case .noTags: "Do not fetch tags"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .default: "Follow Git's normal tag-following behavior."
        case .pruneTags: "Use --prune-tags so deleted remote tags are removed locally."
        case .allTags: "Use --tags to fetch every tag from each fetched remote."
        case .noTags: "Use --no-tags for fetches that should not update local tags."
        }
    }

    var engineValue: FetchTagsMode {
        switch self {
        case .default: .default
        case .pruneTags: .pruneTags
        case .allTags: .allTags
        case .noTags: .noTags
        }
    }

    init(engineValue: FetchTagsMode) {
        switch engineValue {
        case .default: self = .default
        case .pruneTags: self = .pruneTags
        case .allTags: self = .allTags
        case .noTags: self = .noTags
        }
    }
}

enum GitFetchTagsSettings {
    private static let projectKeyPrefix = "arbor.git.fetchTagsMode.project.v1:"

    private static func key(for projectPath: String) -> String {
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }

    static func mode(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitFetchTagsModeChoice {
        guard let projectPath, !projectPath.isEmpty,
              let raw = defaults.string(forKey: key(for: projectPath)),
              let mode = GitFetchTagsModeChoice(rawValue: raw) else {
            return .default
        }
        return mode
    }

    static func save(
        _ mode: GitFetchTagsModeChoice,
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) {
        if mode == .default {
            defaults.removeObject(forKey: key(for: projectPath))
        } else {
            defaults.set(mode.rawValue, forKey: key(for: projectPath))
        }
    }
}

/// Project-level equivalent of IntelliJ's GitVcsSettings.updateMethod.
enum GitUpdateMethodChoice: String, CaseIterable, Identifiable, Sendable {
    case merge
    case rebase

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .merge: "Update Project fetches and integrates upstream changes with a merge."
        case .rebase: "Update Project fetches and replays local commits on top of upstream."
        }
    }
}

enum GitUpdateMethodSettings {
    private static let projectKeyPrefix = "arbor.git.updateMethod.project.v1:"

    private static func key(for projectPath: String) -> String {
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }

    static func method(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitUpdateMethodChoice {
        guard let projectPath, !projectPath.isEmpty,
              let raw = defaults.string(forKey: key(for: projectPath)),
              let method = GitUpdateMethodChoice(rawValue: raw) else {
            return .merge
        }
        return method
    }

    static func save(
        _ method: GitUpdateMethodChoice,
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) {
        if method == .merge {
            defaults.removeObject(forKey: key(for: projectPath))
        } else {
            defaults.set(method.rawValue, forKey: key(for: projectPath))
        }
    }
}

/// Project-level equivalent of IntelliJ's Git update-info structure filter.
/// Store root-qualified selections rather than only text so equal relative
/// paths in different Git roots remain independent.
enum GitUpdateInfoPathFilterSettings {
    private static let projectKeyPrefix = "arbor.git.updateInfoPathFilter.project.v1:"

    private static func key(for projectPath: String) -> String {
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }

    static func selections(
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) -> [LogPathFilterSelection] {
        guard let data = defaults.data(forKey: key(for: projectPath)),
              let values = try? JSONDecoder().decode([LogPathFilterSelection].self, from: data) else {
            return []
        }
        return normalizedLogPathFilterSelections(values)
    }

    static func text(
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) -> String {
        logPathFilterEditorText(selections(for: projectPath, defaults: defaults))
    }

    static func save(
        _ rawText: String,
        roots: [String],
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) {
        let selections = parseLogPathFilterEditorText(rawText, roots: roots)
        let normalized = normalizedLogPathFilterSelections(selections)
        guard !normalized.isEmpty else {
            defaults.removeObject(forKey: key(for: projectPath))
            return
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: key(for: projectPath))
    }
}

/// Global equivalent of IntelliJ's `git.update.info.auto.open.enabled` advanced
/// setting. Update Info is enabled by default, but users can keep the current
/// Log tab and use the notification action instead.
enum GitUpdateInfoAutoOpenSettings {
    static let key = "arbor.git.updateInfo.autoOpen.v1"
    static let defaultValue = true

    static func value(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func save(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    static func shouldAutoOpen(
        ranges: [PersistedLogRevisionRange],
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(defaults: defaults) && !ranges.isEmpty
    }
}

/// Project-scoped equivalent of IntelliJ's standard UpdateOptionsDialog
/// "Do not show again" option. The default is to show the dialog, matching
/// the platform VCS update flow for a newly opened project.
enum GitUpdateOptionsDialogSettings {
    private static let projectKeyPrefix = "arbor.git.updateOptionsDialog.show.project.v1:"

    private static func key(for projectPath: String) -> String {
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }

    static func shouldShow(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let projectPath, !projectPath.isEmpty else { return true }
        return defaults.object(forKey: key(for: projectPath)) as? Bool ?? true
    }

    static func saveShouldShow(
        _ shouldShow: Bool,
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(shouldShow, forKey: key(for: projectPath))
    }
}
