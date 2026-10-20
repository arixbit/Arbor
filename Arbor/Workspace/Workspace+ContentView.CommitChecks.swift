import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

struct BeforeCommitCheckError: Error {
    let command: String
    let output: String
}

nonisolated func runBeforeCommitChecks(repo: Repository, commands: [BeforeCommitCommand]) throws {
    for item in commands {
        let outcome = try repo.runCheckCommand(command: item.command, args: item.args)
        guard outcome.success else {
            throw BeforeCommitCheckError(command: item.display, output: outcome.output)
        }
    }
}

struct CommitWarningPresentation: Sendable, Hashable {
    let setting: GitCommitWarningSetting
    let rootLabel: String
    let message: String
}

struct CommitWarningDecision: Sendable {
    let shouldContinue: Bool
    let setCoreAutocrlf: Bool
}

nonisolated func commitWarningOrder(_ setting: GitCommitWarningSetting) -> Int {
    switch setting {
    case .crlf: return 0
    case .largeFile: return 1
    case .detachedHead: return 2
    case .badFileName: return 3
    }
}

nonisolated func commitWarningPresentations(
    _ checks: [CommitCheckResult],
    rootLabel: String,
    projectPath: String?
) -> [CommitWarningPresentation] {
    checks.compactMap { check in
        guard !check.blocking,
              let setting = commitWarningSetting(for: check.kind),
              GitCommitWarningSettings.warningEnabled(setting, for: projectPath) else {
            return nil
        }
        return CommitWarningPresentation(
            setting: setting,
            rootLabel: rootLabel,
            message: check.message
        )
    }.sorted { lhs, rhs in
        commitWarningOrder(lhs.setting) < commitWarningOrder(rhs.setting)
    }
}

func presentCommitWarningDecision(
    _ warnings: [CommitWarningPresentation],
    projectPath: String?
) -> CommitWarningDecision {
    guard !warnings.isEmpty else {
        return CommitWarningDecision(shouldContinue: true, setCoreAutocrlf: false)
    }

    // IntelliJ runs CommitCheck handlers in order and presents the first
    // unresolved CommitProblem as a modal decision. Keeping one warning per
    // dialog matters when a commit spans multiple roots: the user can accept
    // a large-file warning while still cancelling a later detached-HEAD or
    // filename warning, and each "don't warn again" choice remains scoped to
    // its own warning category.
    var setCoreAutocrlf = false
    var seenSettings = Set<GitCommitWarningSetting>()
    for warning in warnings {
        guard !seenSettings.contains(warning.setting) else { continue }

        let alert = NSAlert()
        alert.messageText = "Commit warning: \(warning.setting.title)"
        let prefix = warning.rootLabel.isEmpty ? "" : "\(warning.rootLabel): "
        alert.informativeText = "\(prefix)\(warning.message)"
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't warn about this again in this project"
        if warning.setting == .crlf {
            alert.addButton(withTitle: "Set core.autocrlf and Commit")
        }
        alert.addButton(withTitle: "Commit Anyway")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let isCrlfFix = warning.setting == .crlf
            && response == .alertFirstButtonReturn
        let commitResponse: NSApplication.ModalResponse = warning.setting == .crlf
            ? .alertSecondButtonReturn
            : .alertFirstButtonReturn
        guard isCrlfFix || response == commitResponse else {
            return CommitWarningDecision(shouldContinue: false, setCoreAutocrlf: false)
        }
        seenSettings.insert(warning.setting)

        if alert.suppressionButton?.state == .on {
            if !(isCrlfFix && warning.setting == .crlf) {
                GitCommitWarningSettings.saveWarning(false, warning.setting, for: projectPath)
            }
        }
        if isCrlfFix {
            setCoreAutocrlf = true
        }
    }
    return CommitWarningDecision(
        shouldContinue: true,
        setCoreAutocrlf: setCoreAutocrlf
    )
}

nonisolated func collectMultiRootCommitWarnings(
    rootPaths: [String],
    selectedChanges: [MultiRootChangeSelection]?,
    projectPath: String?
) throws -> [CommitWarningPresentation] {
    let selectedPathsByRoot = selectedChanges.map {
        Dictionary(grouping: normalizedMultiRootCommitSelections($0), by: \.rootPath)
            .mapValues { selections in Array(Set(selections.map(\.path)).sorted()) }
    }
    let largeFileLimitBytes = GitCommitWarningSettings.largeFileLimitBytes(for: projectPath)
    var warnings: [CommitWarningPresentation] = []
    for rootPath in rootPaths {
        let repository = try openRepository(path: rootPath)
        let checks: [CommitCheckResult]
        if let paths = selectedPathsByRoot?[rootPath], !paths.isEmpty {
            checks = try repository.commitChecksWithLargeFileLimitForPaths(
                maxFileSizeBytes: largeFileLimitBytes,
                paths: paths
            )
        } else {
            checks = try repository.commitChecksWithLargeFileLimit(
                maxFileSizeBytes: largeFileLimitBytes
            )
        }
        let rootLabel = URL(fileURLWithPath: rootPath).lastPathComponent
        warnings.append(contentsOf: commitWarningPresentations(
            checks,
            rootLabel: rootLabel,
            projectPath: projectPath
        ))
    }
    return warnings
}

}
