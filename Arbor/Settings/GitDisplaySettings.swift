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
