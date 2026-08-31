import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers

/// Application-wide Git annotation settings, matching the fork's
/// `GitVcsApplicationSettings` values. The annotation gutter owns the menu;
/// this small store keeps both the gutter and file viewers on one option set.
enum GitAnnotationSettings {
    static let ignoreWhitespacesKey = "arbor.git.annotation.ignoreWhitespaces.v1"
    static let movementKey = "arbor.git.annotation.movement.v1"
    static let preferCommitDateKey = "arbor.git.annotation.preferCommitDate.v1"
    static let hideAuthorKey = "arbor.git.annotation.hideAuthor.v1"

    static let defaultIgnoreWhitespaces = true
    static let defaultMovement = BlameMovement.none
    static let defaultPreferCommitDate = false
    static let defaultHideAuthor = false

    static func options(from defaults: UserDefaults = .standard) -> BlameOptions {
        let movement: BlameMovement
        switch defaults.string(forKey: movementKey) {
        case "inner":
            movement = .inner
        case "outer":
            movement = .outer
        default:
            movement = defaultMovement
        }
        return BlameOptions(
            ignoreWhitespaces: defaults.object(forKey: ignoreWhitespacesKey) == nil
                ? defaultIgnoreWhitespaces
                : defaults.bool(forKey: ignoreWhitespacesKey),
            movement: movement,
            preferCommitDate: defaults.object(forKey: preferCommitDateKey) == nil
                ? defaultPreferCommitDate
                : defaults.bool(forKey: preferCommitDateKey)
        )
    }
}

/// 结构化、白名单字段的本地诊断日志。
///
/// 记录仓库 basename 而不是完整路径；调用方只传 operation/code，不传错误正文、
/// remote URL、提交消息或文件内容。日志按 5 MiB 滚动，保留当前文件和两个旧文件。
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private struct Record: Encodable {
        let timestamp: String
        let level: String
        let version: String
        let operation: String
        let repository: String?
        let code: String
    }

    private let queue = DispatchQueue(label: "com.arbor.diagnostics", qos: .utility)
    private let osLogger = Logger(subsystem: "com.arbor.app", category: "diagnostics")
    private let encoder = JSONEncoder()
    private let dateFormatter: ISO8601DateFormatter
    private let fileManager = FileManager.default
    private let maxBytes = 5 * 1024 * 1024
    private let retainedFiles = 3

    private var logDirectory: URL {
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Arbor", isDirectory: true)
    }

    private var logURL: URL { logDirectory.appendingPathComponent("arbor.log") }

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatter = formatter
    }

    func record(
        level: OSLogType = .info,
        operation: String,
        repositoryPath: String? = nil,
        code: String
    ) {
        queue.async { [self] in
            do {
                try append(
                    Record(
                        timestamp: dateFormatter.string(from: Date()),
                        level: level == .error ? "error" : "info",
                        version: appVersion,
                        operation: operation,
                        repository: repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                        code: code
                    )
                )
                if level == .error {
                    osLogger.error("operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
                } else {
                    osLogger.info("operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
                }
            } catch {
                osLogger.error("diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 将当前及滚动日志打包到用户明确选择的路径；不上传、不打开网络连接。
    func exportArchive(to destination: URL) throws {
        try queue.sync {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: .atomic)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                logDirectory.path, destination.path
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "Arbor.Diagnostics",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "ditto failed to export diagnostics"]
                )
            }
        }
    }

    func summary() -> String {
        queue.sync {
            let count = (try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil))?.count ?? 0
            return "local JSONL files: \(count); credentials and repository content are excluded"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private func append(_ record: Record) throws {
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        var line = try encoder.encode(record)
        line.append(0x0A)
        let currentSize = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        if currentSize + line.count > maxBytes {
            for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
                let source = logDirectory.appendingPathComponent("arbor.log.\(index)")
                let target = logDirectory.appendingPathComponent("arbor.log.\(index + 1)")
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                if fileManager.fileExists(atPath: source.path) { try fileManager.moveItem(at: source, to: target) }
            }
            let rotated = logDirectory.appendingPathComponent("arbor.log.1")
            if fileManager.fileExists(atPath: rotated.path) { try fileManager.removeItem(at: rotated) }
            if fileManager.fileExists(atPath: logURL.path) { try fileManager.moveItem(at: logURL, to: rotated) }
        }
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: logURL, options: .atomic)
        }
    }
}

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

/// Global equivalent of IntelliJ's
/// `git.in.memory.commit.editing.operations.enabled` registry key. Keep this
/// separate from the rebase dialog preferences: it selects the execution
/// backend for suitable Log-driven history edits, while the todo itself and
/// its recovery state remain operation data.
enum GitInMemoryCommitEditingSettings {
    static let key = "arbor.git.inMemoryCommitEditingOperations.v1"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

func shouldUseInMemoryCommitEditing(
    settingEnabled: Bool,
    items: [RebaseTodoItem],
    preserveMerges: Bool
) -> Bool {
    settingEnabled
        && !preserveMerges
        && !items.contains { $0.action == .edit }
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
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(projectKeyPrefix)\(data.base64EncodedString())"
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
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
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
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
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
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
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

/// Global equivalent of IntelliJ's `git.read.content.with` advanced setting.
/// Historical content defaults to checkout filters, matching IntelliJ; users
/// can opt into raw blobs or Git textconv drivers per revision browser.
enum GitRevisionContentMode: String, CaseIterable, Identifiable {
    case none
    case filters
    case textconv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Raw blob (None)"
        case .filters: "Checkout filters (Filters)"
        case .textconv: "Textconv driver (Textconv)"
        }
    }

    var engineValue: GitContentTransformMode {
        switch self {
        case .none: .none
        case .filters: .filters
        case .textconv: .textconv
        }
    }
}

enum GitRevisionContentSettings {
    static let key = "arbor.git.readRevisionContentWith.v1"
    static let defaultValue = GitRevisionContentMode.filters.rawValue

    static func mode(defaults: UserDefaults = .standard) -> GitRevisionContentMode {
        GitRevisionContentMode(
            rawValue: defaults.string(forKey: key) ?? defaultValue
        ) ?? .filters
    }
}

/// Global equivalent of IntelliJ's `git.branch.cleanup.symbol` advanced
/// setting. The default replacement is the same hyphen used by IntelliJ.
enum GitBranchNameCleanupSettings {
    static let key = "arbor.git.branch.cleanupSymbol.v1"
    static let defaultValue = "-"

    static func symbol(defaults: UserDefaults = .standard) -> String {
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return defaultValue
        }
        return value
    }
}

/// Port of GitRefNameValidator's typing and final cleanup rules. The Git
/// engine remains authoritative, while this keeps the dialog interaction
/// aligned with IntelliJ before the value reaches the FFI boundary.
enum GitBranchNameCleanup {
    private static let dropPattern = "(^\\.)|(^-)|(^/)|[~:^?*\"\\[\\\\]+|(@\\{)+|/(?=/)|(\\.(?=\\.))+|\\.(?=/)|(?<=/)\\."
    private static let endingPattern = "(([./]|\\.lock)$)"

    static func cleanUpOnTyping(
        _ branchName: String,
        defaults: UserDefaults = .standard
    ) -> String {
        let dropped = branchName.replacingOccurrences(
            of: dropPattern,
            with: "",
            options: .regularExpression
        )
        let symbol = GitBranchNameCleanupSettings.symbol(defaults: defaults)
        var result = ""
        var inSpaceRun = false
        for scalar in dropped.unicodeScalars {
            if scalar.value == 0x20 {
                if !inSpaceRun { result.append(contentsOf: symbol) }
                inSpaceRun = true
            } else {
                inSpaceRun = false
                if scalar.value <= 0x1F || scalar.value == 0x7F {
                    result.append(contentsOf: symbol)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    static func cleanUp(
        _ branchName: String,
        defaults: UserDefaults = .standard
    ) -> String {
        cleanUpOnTyping(branchName, defaults: defaults)
            .replacingOccurrences(
                of: endingPattern,
                with: "",
                options: .regularExpression
            )
    }
}

/// Global equivalent of IntelliJ's `git.commit.do.not.run.commit.hooks`.
/// The setting is an override: a per-commit choice to skip hooks remains
/// respected when this global switch is off.
enum GitCommitHooksSettings {
    static let key = "arbor.git.commit.alwaysSkipHooks.v1"
    static let defaultValue = false

    static func value(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func effectiveSkipHooks(
        requested: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        requested || value(defaults: defaults)
    }
}

/// Project-scoped equivalent of IntelliJ's standard UpdateOptionsDialog
/// "Do not show again" option. The default is to show the dialog, matching
/// the platform VCS update flow for a newly opened project.
enum GitUpdateOptionsDialogSettings {
    private static let projectKeyPrefix = "arbor.git.updateOptionsDialog.show.project.v1:"

    private static func key(for projectPath: String) -> String {
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return projectKeyPrefix + data.base64EncodedString()
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

enum GitIncomingCheckStrategySettings {
    private static let projectKeyPrefix = "arbor.git.incomingCheckStrategy.project.v1:"
    private static let suggestionCountKeyPrefix = "arbor.git.autoFetchSuggestionCount.project.v1:"
    private static let suggestionDisabledKeyPrefix = "arbor.git.autoFetchSuggestionDisabled.project.v1:"
    private static let globalSuggestionCountKey = "arbor.git.autoFetchSuggestionCount.v1"
    private static let globalSuggestionDisabledKey = "arbor.git.autoFetchSuggestionDisabled.v1"

    static func projectKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return projectKeyPrefix + data.base64EncodedString()
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

struct ProjectGitIncomingChangesSettingsView: View {
    let projectPath: String
    let rootPaths: [String]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: GitIncomingProjectSettingChoice
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @State private var rootSyncChoice: GitRootSyncChoice
    @State private var useProjectProtectedBranchSettings: Bool
    @State private var protectedBranchPatterns: String
    @State private var synchronizeProtectedBranches: Bool
    @State private var useProjectGitExecutable: Bool
    @State private var projectGitExecutablePath: String
    @State private var projectGitExecutableStatus = ""
    @State private var projectGitExecutableSaveError: String?
    @State private var fetchTagsMode: GitFetchTagsModeChoice
    @State private var updateMethod: GitUpdateMethodChoice
    @State private var updateInfoPathFilterText: String
    @State private var useProjectLocalChangesSavePolicy: Bool
    @State private var localChangesSavePolicy: GitLocalChangesSavePolicyChoice
    @State private var useProjectPushAfterCommitPreview: Bool
    @State private var pushAfterCommitPreview: GitPushAfterCommitPreviewChoice
    @State private var useProjectCherryPickSettings: Bool
    @State private var projectCherryPickAppendPublishedSuffix: Bool
    @State private var useProjectPushTagSettings: Bool
    @State private var projectPushTagMode: PushDialogTagMode
    @State private var autoUpdateIfPushRejected: Bool
    @State private var signOffCommit: Bool
    @State private var swapSidesInCompareBranches: Bool
    @State private var resetMode: GitResetModeChoice
    @State private var warnAboutCrlf: Bool
    @State private var warnAboutDetachedHead: Bool
    @State private var warnAboutLargeFiles: Bool
    @State private var warnAboutBadFileNames: Bool
    @State private var largeFileLimitMBText: String

    init(
        projectPath: String,
        rootPaths: [String] = [],
        onSaved: @escaping () -> Void
    ) {
        self.projectPath = projectPath
        self.rootPaths = rootPaths
        self.onSaved = onSaved
        _choice = State(
            initialValue: GitIncomingCheckStrategySettings.projectChoice(for: projectPath)
        )
        _rootSyncChoice = State(
            initialValue: GitRootSyncSettings.choice(for: projectPath)
        )
        let projectPatterns = GitProtectedBranchRules.projectRawValue(for: projectPath)
        let projectSynchronize = GitProtectedBranchRules.projectSynchronizeValue(for: projectPath)
        _useProjectProtectedBranchSettings = State(
            initialValue: projectPatterns != nil || projectSynchronize != nil
        )
        _protectedBranchPatterns = State(
            initialValue: projectPatterns ?? GitProtectedBranchRules.globalRawValue()
        )
        _synchronizeProtectedBranches = State(
            initialValue: projectSynchronize
                ?? GitProtectedBranchRules.synchronizeRemotePatterns()
        )
        let projectGitExecutable = GitExecutableSettings.projectOverride(for: projectPath)
        _useProjectGitExecutable = State(initialValue: projectGitExecutable != nil)
        _projectGitExecutablePath = State(initialValue: projectGitExecutable ?? gitExecutable())
        _fetchTagsMode = State(initialValue: GitFetchTagsSettings.mode(for: projectPath))
        _updateMethod = State(initialValue: GitUpdateMethodSettings.method(for: projectPath))
        _updateInfoPathFilterText = State(
            initialValue: GitUpdateInfoPathFilterSettings.text(for: projectPath)
        )
        let projectSavePolicy = GitProjectLocalChangesSavePolicySettings.choice(for: projectPath)
        _useProjectLocalChangesSavePolicy = State(initialValue: projectSavePolicy != nil)
        _localChangesSavePolicy = State(
            initialValue: projectSavePolicy ?? GitLocalChangesSavePolicySettings.choice()
        )
        let projectPushPreview = GitPushAfterCommitSettings.projectChoice(for: projectPath)
        _useProjectPushAfterCommitPreview = State(initialValue: projectPushPreview != nil)
        _pushAfterCommitPreview = State(
            initialValue: projectPushPreview
                ?? GitPushAfterCommitSettings.choice(from: UserDefaults.standard)
        )
        let projectCherryPickSuffix = GitCherryPickSettings.projectAppendPublishedSuffix(
            for: projectPath
        )
        _useProjectCherryPickSettings = State(initialValue: projectCherryPickSuffix != nil)
        _projectCherryPickAppendPublishedSuffix = State(
            initialValue: projectCherryPickSuffix
                ?? GitCherryPickSettings.appendPublishedSuffix()
        )
        let projectPushTagMode = GitPushTagSettings.projectTagMode(for: projectPath)
        _useProjectPushTagSettings = State(
            initialValue: GitPushTagSettings.hasProjectOverride(for: projectPath)
        )
        _projectPushTagMode = State(initialValue: projectPushTagMode ?? .all)
        _autoUpdateIfPushRejected = State(
            initialValue: GitPushAutoUpdateSettings.value(for: projectPath)
        )
        _signOffCommit = State(
            initialValue: GitSignOffCommitSettings.value(for: projectPath)
        )
        _swapSidesInCompareBranches = State(
            initialValue: GitCompareBranchesSettings.swapSides(for: projectPath)
        )
        _resetMode = State(
            initialValue: GitResetModeSettings.mode(for: projectPath)
        )
        _warnAboutCrlf = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.crlf, for: projectPath)
        )
        _warnAboutDetachedHead = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.detachedHead, for: projectPath)
        )
        _warnAboutLargeFiles = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.largeFile, for: projectPath)
        )
        _warnAboutBadFileNames = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.badFileName, for: projectPath)
        )
        _largeFileLimitMBText = State(
            initialValue: String(GitCommitWarningSettings.largeFileLimitMB(for: projectPath))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Git Settings")
                .font(.title2.weight(.semibold))
            Text(projectPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Form {
                Picker("Incoming changes check", selection: $choice) {
                    ForEach(GitIncomingProjectSettingChoice.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .disabled(!incomingOutgoingInfoEnabled)
                Text("This setting applies only to this project. Use the global setting to inherit the app-wide Git preference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !incomingOutgoingInfoEnabled {
                    Text("Incoming and outgoing branch information is disabled by the global Git advanced setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("LS_REMOTE checks configured upstreams without changing local refs; Auto-fetch checks every Git root every 20 minutes by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Section("Update Project") {
                    Picker("Update method", selection: $updateMethod) {
                        ForEach(GitUpdateMethodChoice.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(updateMethod.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This setting applies to Update Project (⌘T), including every discovered Git root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Update Info path filter")
                        TextEditor(text: $updateInfoPathFilterText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 64, maxHeight: 120)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            }
                        Text("One path per line; use an absolute path to target one Git root. Leave empty to show all updated paths.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Use project-specific local changes policy",
                        isOn: $useProjectLocalChangesSavePolicy
                    )
                    Picker("Save local changes as", selection: $localChangesSavePolicy) {
                        ForEach(GitLocalChangesSavePolicyChoice.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!useProjectLocalChangesSavePolicy)
                    Text(localChangesSavePolicy.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        useProjectLocalChangesSavePolicy
                            ? "This project policy is used by Pull, Update Project, Rebase, Merge, Reset, and smart checkout operations."
                            : "This project inherits the application Local Changes Preservation setting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Branch operations") {
                    Picker("Cross-root action scope", selection: $rootSyncChoice) {
                        ForEach(GitRootSyncChoice.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(rootSyncChoice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This project setting controls whether same-name Branch Popup actions can target multiple Git roots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fetch tags") {
                    Picker("Tag handling", selection: $fetchTagsMode) {
                        ForEach(GitFetchTagsModeChoice.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(fetchTagsMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This project setting applies to Fetch, Fetch All, Pull, Checkout and Update, remote-branch Fetch, incoming-change checks, and Push recovery updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Commit and Push") {
                    Toggle(
                        "Use project-specific Push-after-commit behavior",
                        isOn: $useProjectPushAfterCommitPreview
                    )
                    Picker("After Commit and Push", selection: $pushAfterCommitPreview) {
                        ForEach(GitPushAfterCommitPreviewChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!useProjectPushAfterCommitPreview)
                    Text(pushAfterCommitPreview.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        useProjectPushAfterCommitPreview
                            ? "This project overrides the application Push-after-commit behavior."
                            : "This project inherits the application Push-after-commit behavior."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Commit defaults") {
                    Toggle(
                        "Add Signed-off-by by default",
                        isOn: $signOffCommit
                    )
                    Text("This project setting is the default for single-root and multi-root Commit dialogs. The existing identity sheet can still change the current session's one-shot commit options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Compare branches") {
                    Toggle(
                        "Swap sides in branch diff",
                        isOn: $swapSidesInCompareBranches
                    )
                    Text(
                        swapSidesInCompareBranches
                            ? "Show the selected branch on the left and the current working tree on the right."
                            : "Show the current working tree on the left and the selected branch on the right."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Reset") {
                    Picker("Default reset mode", selection: $resetMode) {
                        ForEach(GitResetModeChoice.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(resetMode.detail)
                        .font(.caption)
                        .foregroundStyle(resetMode == .hard ? .red : .secondary)
                    Text("Reset dialogs remember the last mode selected in this project. Hard reset remains explicitly destructive and requires confirmation in the dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Commit warnings") {
                    Toggle("Warn about mixed CRLF/LF line endings", isOn: $warnAboutCrlf)
                    Toggle("Warn when committing with detached HEAD", isOn: $warnAboutDetachedHead)
                    Toggle("Warn about large staged files", isOn: $warnAboutLargeFiles)
                    HStack {
                        Text("Large-file threshold (MB)")
                        Spacer()
                        TextField("50", text: $largeFileLimitMBText)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    .disabled(!warnAboutLargeFiles)
                    Toggle("Warn about Windows-incompatible file names", isOn: $warnAboutBadFileNames)
                    Text("These checks run before single-root and multi-root Commit. Continue or cancel is offered for each warning group; choosing not to warn again disables that warning for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Cherry-pick") {
                    Toggle(
                        "Use project-specific Cherry-pick behavior",
                        isOn: $useProjectCherryPickSettings
                    )
                    Toggle(
                        "Add published-commit suffix",
                        isOn: $projectCherryPickAppendPublishedSuffix
                    )
                    .disabled(!useProjectCherryPickSettings)
                    Text(
                        useProjectCherryPickSettings
                            ? "This project overrides whether Cherry-pick adds the suffix for commits already reachable from a protected remote branch."
                            : "This project inherits the application Cherry-pick suffix setting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Push tags") {
                    Toggle(
                        "Use project-specific Push tag mode",
                        isOn: $useProjectPushTagSettings
                    )
                    Picker("Default tag mode", selection: $projectPushTagMode) {
                        ForEach(PushDialogTagMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!useProjectPushTagSettings)
                    Text(
                        useProjectPushTagSettings
                            ? "Push dialogs default to this tag mode for this project; the user can still disable Push tags per operation."
                            : "Push dialogs default to Push tags off for this project."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Push recovery") {
                    Toggle(
                        "Auto-update if current-branch Push is rejected",
                        isOn: $autoUpdateIfPushRejected
                    )
                    Text("When a Push of the checked-out branch is rejected because the remote is ahead, Arbor updates the project roots with the selected Update method and retries. Force pushes, custom refspecs, non-current branches, and branches without an upstream remain manual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Git Executable") {
                    Toggle(
                        "Use project-specific Git executable",
                        isOn: $useProjectGitExecutable
                    )
                    HStack(spacing: 8) {
                        TextField("Path to Git executable", text: $projectGitExecutablePath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!useProjectGitExecutable)
                        Button("Browse…", action: chooseProjectGitExecutable)
                            .disabled(!useProjectGitExecutable)
                    }
                    HStack(spacing: 8) {
                        Button("Test Git executable", action: testProjectGitExecutable)
                            .disabled(!useProjectGitExecutable || projectGitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !projectGitExecutableStatus.isEmpty {
                            Text(projectGitExecutableStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let projectGitExecutableSaveError {
                        Label(projectGitExecutableSaveError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    Text(
                        useProjectGitExecutable
                            ? "This executable is used by this project’s registered Git roots and overrides the application default."
                            : "This project inherits the application Git executable."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle(
                    "Use project-specific protected branch rules",
                    isOn: $useProjectProtectedBranchSettings
                )
                .help("When disabled, this project inherits the global protected branch settings.")
                ProjectGitProtectedBranchesSettingsSection(
                    patterns: $protectedBranchPatterns,
                    synchronize: $synchronizeProtectedBranches
                )
                .disabled(!useProjectProtectedBranchSettings)
                if !useProjectProtectedBranchSettings {
                    Text("This project inherits the global protected branch patterns and synchronization setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    guard saveProjectGitExecutable() else { return }
                    GitIncomingCheckStrategySettings.saveProjectStrategy(
                        choice.strategy,
                        for: projectPath
                    )
                    GitRootSyncSettings.save(rootSyncChoice, for: projectPath)
                    GitFetchTagsSettings.save(fetchTagsMode, for: projectPath)
                    GitUpdateMethodSettings.save(updateMethod, for: projectPath)
                    GitUpdateInfoPathFilterSettings.save(
                        updateInfoPathFilterText,
                        roots: rootPaths,
                        for: projectPath
                    )
                    GitProjectLocalChangesSavePolicySettings.save(
                        useProjectLocalChangesSavePolicy ? localChangesSavePolicy : nil,
                        for: projectPath
                    )
                    GitPushAfterCommitSettings.saveProjectChoice(
                        useProjectPushAfterCommitPreview ? pushAfterCommitPreview : nil,
                        for: projectPath
                    )
                    GitCherryPickSettings.saveProjectAppendPublishedSuffix(
                        useProjectCherryPickSettings
                            ? projectCherryPickAppendPublishedSuffix
                            : nil,
                        for: projectPath
                    )
                    GitPushTagSettings.saveProjectTagMode(
                        useProjectPushTagSettings ? projectPushTagMode : nil,
                        for: projectPath
                    )
                    GitPushAutoUpdateSettings.save(
                        autoUpdateIfPushRejected,
                        for: projectPath
                    )
                    GitSignOffCommitSettings.saveProjectValue(
                        signOffCommit,
                        for: projectPath
                    )
                    GitCompareBranchesSettings.saveSwapSides(
                        swapSidesInCompareBranches,
                        for: projectPath
                    )
                    GitResetModeSettings.save(
                        resetMode,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutCrlf,
                        .crlf,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutDetachedHead,
                        .detachedHead,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutLargeFiles,
                        .largeFile,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveLargeFileLimitMB(
                        Int(largeFileLimitMBText.trimmingCharacters(in: .whitespacesAndNewlines))
                            ?? GitCommitWarningSettings.defaultLargeFileLimitMB,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutBadFileNames,
                        .badFileName,
                        for: projectPath
                    )
                    if useProjectProtectedBranchSettings {
                        GitProtectedBranchRules.saveProjectPatterns(
                            protectedBranchPatterns,
                            for: projectPath
                        )
                        GitProtectedBranchRules.saveProjectSynchronize(
                            synchronizeProtectedBranches,
                            for: projectPath
                        )
                    } else {
                        GitProtectedBranchRules.saveProjectPatterns(nil, for: projectPath)
                        GitProtectedBranchRules.saveProjectSynchronize(nil, for: projectPath)
                    }
                    onSaved()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseProjectGitExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            projectGitExecutablePath = url.path
            projectGitExecutableStatus = ""
            projectGitExecutableSaveError = nil
        }
    }

    private func testProjectGitExecutable() {
        let candidate = projectGitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        projectGitExecutableStatus = "Testing…"
        projectGitExecutableSaveError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let version = try testGitExecutable(path: candidate)
                await MainActor.run {
                    projectGitExecutableStatus = version
                }
            } catch {
                await MainActor.run {
                    projectGitExecutableStatus = "Test failed: \(error)"
                }
            }
        }
    }

    private func saveProjectGitExecutable() -> Bool {
        projectGitExecutableSaveError = nil
        if !useProjectGitExecutable {
            GitExecutableSettings.saveProjectOverride(nil, for: projectPath)
            clearProjectGitExecutable(projectPath: projectPath)
            return true
        }

        let candidate = projectGitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            projectGitExecutableSaveError = "Project Git executable path must not be empty."
            return false
        }
        do {
            let roots = GitExecutableSettings.registeredRoots(
                projectPath: projectPath,
                repositoryRoot: nil,
                discoveredRoots: rootPaths
            )
            let selected = try setProjectGitExecutable(
                projectPath: projectPath,
                rootPaths: roots,
                path: candidate
            )
            GitExecutableSettings.saveProjectOverride(selected, for: projectPath)
            projectGitExecutablePath = selected
            projectGitExecutableStatus = "Saved: \(selected)"
            return true
        } catch {
            projectGitExecutableSaveError = "Save failed: \(error)"
            return false
        }
    }
}

struct DiagnosticsSettingsView: View {
    @State private var status = ""
    @State private var showReportConfirmation = false
    @State private var showGpgAgentSettings = false
    @AppStorage("arbor.autoCheckForUpdates") private var autoCheckForUpdates = false
    @AppStorage("arbor.git.useCredentialHelper") private var useCredentialHelper = false
    @AppStorage("arbor.git.autoFetch.v1") private var gitAutoFetch = false
    @AppStorage("arbor.git.externalConversion.v1") private var gitExternalConversionEnabled = false
    @AppStorage(GitIncomingCheckStrategy.userDefaultsKey)
    private var incomingCheckStrategyRaw = GitIncomingCheckStrategy.none.rawValue
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @AppStorage(GitInMemoryCommitEditingSettings.key)
    private var inMemoryCommitEditingEnabled = GitInMemoryCommitEditingSettings.defaultValue
    @AppStorage(GitVFSListenerSettings.addActionKey)
    private var gitVFSAddActionRaw = GitVFSListenerAction.ask.rawValue
    @AppStorage(GitVFSListenerSettings.removeActionKey)
    private var gitVFSRemoveActionRaw = GitVFSListenerAction.ask.rawValue
    @AppStorage(GitCloneSettings.recurseSubmodulesKey)
    private var cloneRecursiveSubmodules = GitCloneSettings.defaultRecurseSubmodules
    @AppStorage(GitUpdateInfoAutoOpenSettings.key)
    private var gitUpdateInfoAutoOpen = GitUpdateInfoAutoOpenSettings.defaultValue
    @AppStorage(GitRevisionContentSettings.key)
    private var gitRevisionContentModeRaw = GitRevisionContentSettings.defaultValue
    @AppStorage(GitCommitHooksSettings.key)
    private var gitAlwaysSkipCommitHooks = GitCommitHooksSettings.defaultValue
    @AppStorage(GitBranchNameCleanupSettings.key)
    private var gitBranchCleanupSymbol = GitBranchNameCleanupSettings.defaultValue

    private var incomingCheckStrategy: GitIncomingCheckStrategy {
        resolveGitIncomingCheckStrategy(
            storedRawValue: UserDefaults.standard.object(forKey: GitIncomingCheckStrategy.userDefaultsKey) == nil
                ? nil
                : incomingCheckStrategyRaw,
            legacyAutoFetch: gitAutoFetch
        )
    }

    private var incomingCheckStrategyBinding: Binding<GitIncomingCheckStrategy> {
        Binding(
            get: { incomingCheckStrategy },
            set: { strategy in
                incomingCheckStrategyRaw = strategy.rawValue
                gitAutoFetch = strategy.legacyAutoFetch
            }
        )
    }

    var body: some View {
        Form {
            AppLanguageSettingsSection()
            GitExecutableSettingsSection()
            GitProtectedBranchesSettingsSection()
            GitProtectedBranchSyncSettingsSection()
            GitPushSettingsSection()
            GitLocalChangesSavePolicySettingsSection()
            GitDropCommitSettingsSection()
            GitChangelistSettingsSection()
            GitCherryPickSettingsSection()
            GitMergeSettingsSection()

            Section("Git History Editing") {
                Toggle(
                    "Use in-memory commit editing when possible",
                    isOn: $inMemoryCommitEditingEnabled
                )
                Text("Suitable Log-driven interactive rebase edits use the faster in-memory engine by default. Edits that need a working-directory stop, merge-preserving topology, or the disabled setting use native Git rebase semantics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Commit Signing") {
                Text("Configure the external pinentry used by GPG agent for signed commits. Arbor backs up gpg-agent.conf and reloads the agent after a successful write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Configure GPG Agent…") {
                    showGpgAgentSettings = true
                }
            }

            Section("Git Attributes") {
                Toggle(
                    "Enable Git external conversion and textconv",
                    isOn: $gitExternalConversionEnabled
                )
                Text("关闭时，Arbor 不执行 .gitattributes 中的外部 filter、非 UTF-8 编码或 textconv；开启后通过 system Git 执行，并受单次转换超时保护。Diff Viewer 的 External Diff 仍需用户显式触发，并使用 Git 配置的 difftool。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Historical file content", selection: $gitRevisionContentModeRaw) {
                    ForEach(GitRevisionContentMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Text("Controls Revision Browser content: raw blobs, checkout filters, or the path's textconv driver. Filters is the IntelliJ-compatible default; external conversion remains an explicit safety setting for other attribute-aware operations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Commit Hooks") {
                Toggle(
                    "Always skip Git commit hooks",
                    isOn: $gitAlwaysSkipCommitHooks
                )
                Text("When enabled, all Arbor commit, amend, and commit-and-push operations pass Git's --no-verify behavior. The per-commit checkbox remains checked and is disabled while this override is active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Branch Names") {
                TextField("Cleanup symbol", text: $gitBranchCleanupSymbol)
                Text("When typing a new branch or Push target, invalid Git ref characters are removed and spaces/control characters are replaced with this symbol. The default is '-'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Clone") {
                Toggle(
                    "Initialize and update submodules recursively",
                    isOn: $cloneRecursiveSubmodules
                )
                Text("New clones use Git's recursive submodule initialization when enabled. This is the same default as IntelliJ's git.clone.recurse.submodules setting and is also available in the Clone dialog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("External Git File Changes") {
                Picker("New untracked files", selection: $gitVFSAddActionRaw) {
                    ForEach(GitVFSListenerAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                Picker("Deleted tracked files", selection: $gitVFSRemoveActionRaw) {
                    ForEach(GitVFSListenerAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                Text("These policies apply when another process creates or deletes files in a Git worktree. Reliable paired renames route both endpoints through the same Add/Remove policy; ambiguous renames remain refresh-only for safety.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Authentication") {
                Toggle("Use Git credential helper", isOn: $useCredentialHelper)
                    .onChange(of: useCredentialHelper) { _, enabled in
                        NotificationCenter.default.post(
                            name: .arborGitCredentialHelperSettingChanged,
                            object: enabled
                        )
                    }
                Text("When disabled, remote operations use Arbor's credential dialog instead of configured Git credential helpers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Incoming Changes") {
                Toggle(
                    "Show incoming and outgoing branch information",
                    isOn: $incomingOutgoingInfoEnabled
                )
                Picker("Incoming changes check", selection: incomingCheckStrategyBinding) {
                    ForEach(GitIncomingCheckStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .disabled(!incomingOutgoingInfoEnabled)
                Text("LS_REMOTE checks configured upstreams without changing local refs; Auto-fetch checks every Git root every 20 minutes by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !incomingOutgoingInfoEnabled {
                    Text("The saved incoming-change strategy is retained but inactive until this advanced setting is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Git Update Project") {
                Toggle(
                    "Automatically open the Update Info tab after Update Project",
                    isOn: $gitUpdateInfoAutoOpen
                )
                Text("When enabled, a successful update with received commits opens the dedicated Update Info Log tab. Disable this to keep the current Log tab and use View Commits from the notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Text("每个窗口只围绕一个项目；新项目可从工具栏打开并选择替换或新窗口。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("自动检查更新", isOn: $autoCheckForUpdates)
                    .disabled(true)
                Text("更新检查将在 v0.14 接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Text("Arbor records operation names, version, repository basename, and error codes only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Export Logs…") { exportLogs() }
                Button("Report a Problem…") { showReportConfirmation = true }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .alert("Open a prefilled GitHub issue?", isPresented: $showReportConfirmation) {
            Button("Open Browser") { openIssueURL() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the version, system version, and a sanitized local log summary will be included.")
        }
        .sheet(isPresented: $showGpgAgentSettings) {
            GpgAgentSettingsView()
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Arbor-Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsLogger.shared.exportArchive(to: url)
            status = "已导出：\(url.lastPathComponent)"
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }

    private func openIssueURL() {
        var components = URLComponents(string: "https://github.com/arbor/arbor/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Arbor issue"),
            URLQueryItem(
                name: "body",
                value: "Arbor version: \(appVersion)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nDiagnostics: \(DiagnosticsLogger.shared.summary())\n\nReproduction:\n"
            )
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
