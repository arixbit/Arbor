import SwiftUI
import AppKit
import UniformTypeIdentifiers


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
