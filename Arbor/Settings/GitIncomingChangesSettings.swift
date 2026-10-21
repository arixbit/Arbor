import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers


enum GitIncomingCheckStrategy: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case lsRemote
    case fetch

    static let userDefaultsKey = "arbor.git.incomingCheckStrategy.v2"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .none: "Do not check incoming changes"
        case .lsRemote: "Check remote only (LS_REMOTE)"
        case .fetch: "Auto-fetch incoming changes"
        }
    }

    var legacyAutoFetch: Bool { self == .fetch }
}

/// Global equivalent of IntelliJ's `git.update.incoming.outgoing.info`
/// advanced setting. Keep the stored strategy intact while disabled so
/// re-enabling the setting restores the user's previous choice.
enum GitIncomingOutgoingInfoSettings {
    static let key = "arbor.git.incomingOutgoingInfo.v1"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

func resolveGitIncomingCheckStrategy(
    storedRawValue: String?,
    legacyAutoFetch: Bool
) -> GitIncomingCheckStrategy {
    guard let storedRawValue else {
        // IntelliJ's project Git settings default to the non-mutating
        // LS_REMOTE strategy. Preserve an explicitly stored v2 value, while
        // migrating the old boolean Auto-fetch setting to FETCH when it was
        // enabled.
        return legacyAutoFetch ? .fetch : .lsRemote
    }
    return GitIncomingCheckStrategy(rawValue: storedRawValue) ?? .none
}

enum GitIncomingProjectSettingChoice: String, CaseIterable, Identifiable, Sendable {
    case useGlobal
    case none
    case lsRemote
    case fetch

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .useGlobal: "Use global Git setting"
        case .none: "Do not check incoming changes"
        case .lsRemote: "Check remote only (LS_REMOTE)"
        case .fetch: "Auto-fetch incoming changes"
        }
    }

    var strategy: GitIncomingCheckStrategy? {
        switch self {
        case .useGlobal: nil
        case .none: GitIncomingCheckStrategy.none
        case .lsRemote: .lsRemote
        case .fetch: .fetch
        }
    }

    init(strategy: GitIncomingCheckStrategy?) {
        guard let strategy else {
            self = .useGlobal
            return
        }
        switch strategy {
        case .none: self = .none
        case .lsRemote: self = .lsRemote
        case .fetch: self = .fetch
        }
    }
}

enum GitIncomingCheckStrategySettings {
    private static let projectKeyPrefix = "arbor.git.incomingCheckStrategy.project.v1:"
    private static let suggestionCountKeyPrefix = "arbor.git.autoFetchSuggestionCount.project.v1:"
    private static let suggestionDisabledKeyPrefix = "arbor.git.autoFetchSuggestionDisabled.project.v1:"
    private static let globalSuggestionCountKey = "arbor.git.autoFetchSuggestionCount.v1"
    private static let globalSuggestionDisabledKey = "arbor.git.autoFetchSuggestionDisabled.v1"

    static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }

    private static func suggestionCountKey(for projectPath: String?) -> String? {
        projectKey(for: projectPath).map {
            suggestionCountKeyPrefix + String($0.dropFirst(projectKeyPrefix.count))
        }
    }

    private static func suggestionDisabledKey(for projectPath: String?) -> String? {
        projectKey(for: projectPath).map {
            suggestionDisabledKeyPrefix + String($0.dropFirst(projectKeyPrefix.count))
        }
    }

    static func projectRawValue(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let key = projectKey(for: projectPath) else { return nil }
        return defaults.string(forKey: key)
    }

    static func projectChoice(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitIncomingProjectSettingChoice {
        let raw = projectRawValue(for: projectPath, defaults: defaults)
        let strategy = raw.flatMap(GitIncomingCheckStrategy.init(rawValue:))
        return GitIncomingProjectSettingChoice(strategy: strategy)
    }

    static func saveProjectStrategy(
        _ strategy: GitIncomingCheckStrategy?,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(for: projectPath) else { return }
        if let strategy {
            defaults.set(strategy.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func effectiveStrategy(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitIncomingCheckStrategy {
        guard GitIncomingOutgoingInfoSettings.isEnabled(defaults: defaults) else {
            return .none
        }
        if let raw = projectRawValue(for: projectPath, defaults: defaults),
           let strategy = GitIncomingCheckStrategy(rawValue: raw) {
            return strategy
        }
        return resolveGitIncomingCheckStrategy(
            storedRawValue: defaults.object(forKey: GitIncomingCheckStrategy.userDefaultsKey) == nil
                ? nil
                : defaults.string(forKey: GitIncomingCheckStrategy.userDefaultsKey),
            legacyAutoFetch: defaults.bool(forKey: "arbor.git.autoFetch.v1")
        )
    }

    static func suggestionCount(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard let key = suggestionCountKey(for: projectPath) else {
            return defaults.integer(forKey: globalSuggestionCountKey)
        }
        return defaults.integer(forKey: key)
    }

    static func setSuggestionCount(
        _ count: Int,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = suggestionCountKey(for: projectPath) else {
            defaults.set(count, forKey: globalSuggestionCountKey)
            return
        }
        defaults.set(count, forKey: key)
    }

    static func suggestionDisabled(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = suggestionDisabledKey(for: projectPath) else {
            return defaults.bool(forKey: globalSuggestionDisabledKey)
        }
        return defaults.bool(forKey: key)
    }

    static func setSuggestionDisabled(
        _ disabled: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = suggestionDisabledKey(for: projectPath) else {
            defaults.set(disabled, forKey: globalSuggestionDisabledKey)
            return
        }
        defaults.set(disabled, forKey: key)
    }
}
