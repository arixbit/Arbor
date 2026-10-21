import SwiftUI
import AppKit
import UniformTypeIdentifiers


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
        return gitProjectSettingsKey(keyPrefix, for: projectPath)
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
