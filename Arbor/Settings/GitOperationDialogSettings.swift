import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers


struct GitMergeDialogSettings: Codable, Equatable {
    var branch = ""
    var strategyRaw = MergeStrategyChoice.automatic.rawValue
    var useCustomCommitMessage = false
    var noCommit = false
    var noVerify = false
    var allowUnrelatedHistories = false
}

enum GitMergeDialogSettingsStore {
    private static let projectKeyPrefix = "arbor.git.mergeDialog.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func load(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitMergeDialogSettings {
        let legacyStrategy = defaults.string(forKey: "arbor.merge.strategy.v1")
            ?? MergeStrategyChoice.automatic.rawValue
        guard let key = key(for: projectPath),
              let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GitMergeDialogSettings.self, from: data) else {
            var settings = GitMergeDialogSettings()
            settings.strategyRaw = legacyStrategy
            return settings
        }
        return settings
    }

    static func save(
        _ settings: GitMergeDialogSettings,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath),
              let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Project-scoped equivalent of IntelliJ's GitPullSettings. The remote and
/// branch are resolved from the selected root each time; only the option set
/// is persisted between Pull dialogs.
struct GitPullDialogSettings: Codable, Equatable {
    var options: Set<GitPullDialogOption> = []
}

enum GitPullDialogSettingsStore {
    private static let projectKeyPrefix = "arbor.git.pullDialog.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func load(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitPullDialogSettings {
        guard let key = key(for: projectPath),
              let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GitPullDialogSettings.self, from: data) else {
            return GitPullDialogSettings()
        }
        return settings
    }

    static func save(
        _ settings: GitPullDialogSettings,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath),
              let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Project-scoped equivalent of IntelliJ's GitRebaseSettings. Rebase options
/// are dialog preferences, not operation state: an in-flight rebase keeps its
/// own persisted recovery context elsewhere, while the next dialog restores
/// the last upstream/options used for this project.
struct GitRebaseDialogSettings: Codable, Equatable {
    var onto = ""
    var interactive = false
    var preserveMerges = false
    var autoSquash = false
    var keepEmpty = false
    var updateRefs = false
    var root = false

    private enum CodingKeys: String, CodingKey {
        case onto
        case interactive
        case preserveMerges
        case autoSquash
        case keepEmpty
        case updateRefs
        case root
    }

    init(
        onto: String = "",
        interactive: Bool = false,
        preserveMerges: Bool = false,
        autoSquash: Bool = false,
        keepEmpty: Bool = false,
        updateRefs: Bool = false,
        root: Bool = false
    ) {
        self.onto = onto
        self.interactive = interactive
        self.preserveMerges = preserveMerges
        self.autoSquash = autoSquash
        self.keepEmpty = keepEmpty
        self.updateRefs = updateRefs
        self.root = root
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onto = try container.decodeIfPresent(String.self, forKey: .onto) ?? ""
        interactive = try container.decodeIfPresent(Bool.self, forKey: .interactive) ?? false
        preserveMerges = try container.decodeIfPresent(Bool.self, forKey: .preserveMerges) ?? false
        autoSquash = try container.decodeIfPresent(Bool.self, forKey: .autoSquash) ?? false
        keepEmpty = try container.decodeIfPresent(Bool.self, forKey: .keepEmpty) ?? false
        updateRefs = try container.decodeIfPresent(Bool.self, forKey: .updateRefs) ?? false
        root = try container.decodeIfPresent(Bool.self, forKey: .root) ?? false
    }
}

enum GitRebaseDialogSettingsStore {
    private static let projectKeyPrefix = "arbor.git.rebaseDialog.project.v1:"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
    }

    static func load(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> GitRebaseDialogSettings {
        guard let key = key(for: projectPath),
              let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GitRebaseDialogSettings.self, from: data) else {
            return GitRebaseDialogSettings()
        }
        return settings
    }

    static func save(
        _ settings: GitRebaseDialogSettings,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath),
              let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
