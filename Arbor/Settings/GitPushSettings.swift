import SwiftUI
import AppKit
import UniformTypeIdentifiers


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
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
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
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
    }
}

enum GitPushTagSettings {
    private static let projectKeyPrefix = "arbor.git.pushTags.project.v1:"

    private static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return gitProjectSettingsKey(projectKeyPrefix, for: projectPath)
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
                    Text(LocalizedStringKey(choice.title)).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            if let choice = GitPushAfterCommitPreviewChoice(rawValue: pushAfterCommitPreview) {
                Text(LocalizedStringKey(choice.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("A project-specific choice can override this application default in Project Git Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
