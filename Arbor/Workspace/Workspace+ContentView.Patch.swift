import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
    /// Presents the shared IntelliJ-style Create Patch configuration before
    /// any Git process starts. The callback is dispatched after the sheet is
    /// dismissed so a native save panel never competes with SwiftUI modal
    /// presentation.
    func presentPatchExportDialog(
        title: String,
        defaultFileName: String,
        repositoryRootPath: String,
        paths: [String],
        allowsBaseDirectory: Bool,
        onExport: @escaping (PatchExportOptions) -> Void
    ) {
        fileWorkspace.patchExportRequest = PatchExportRequest(
            title: title,
            defaultFileName: defaultFileName,
            repositoryRootPath: repositoryRootPath,
            paths: paths,
            allowsBaseDirectory: allowsBaseDirectory,
            initialCopyToClipboard: PatchExportSettings.copyToClipboard(for: repositoryRootPath),
            initialEncoding: PatchExportSettings.encoding(for: repositoryRootPath),
            onExport: onExport
        )
    }

    func patchExportDestination(
        defaultFileName: String,
        repositoryRootPath: String
    ) -> URL? {
        choosePatchExportDestination(
            defaultFileName: defaultFileName,
            repositoryRootPath: repositoryRootPath
        )
    }

/// Export the selected commit's parent-to-commit diff as a portable patch.
/// Keep the revision arguments separate from the Git command so commit ids
/// and repository content can never become shell syntax. Merge commits use
/// the first parent, matching the default parent shown by the Changes browser.
func createPatchFromLog(_ commit: CommitInfo) {
    guard let repo = logRepository(for: commit) else { return }

    guard let repositoryRootPath = repo.workdir(), !repositoryRootPath.isEmpty else { return }
    presentPatchExportDialog(
        title: "Create Patch",
        defaultFileName: "\(commit.shortId).patch",
        repositoryRootPath: repositoryRootPath,
        paths: [],
        allowsBaseDirectory: false
    ) { options in
        let destination = options.copyToClipboard
            ? nil
            : self.patchExportDestination(
                defaultFileName: "\(commit.shortId).patch",
                repositoryRootPath: repositoryRootPath
            )
        guard options.copyToClipboard || destination != nil else { return }
        PatchExportSettings.save(options, for: repositoryRootPath)

        let command: String
        let baseArguments: [String]
        if let parent = commit.parentIds.first {
            command = "diff"
            baseArguments = ["--binary", "--no-ext-diff", parent, commit.id]
        } else {
            command = "show"
            baseArguments = ["--format=", "--binary", "--no-ext-diff", "--root", commit.id]
        }
        guard let arguments = patchExportGitArguments(
            baseArguments: baseArguments,
            repositoryRootPath: repositoryRootPath,
            paths: [],
            options: options
        ) else { return }

        self.beginFeedbackOperation(options.copyToClipboard ? "Copy patch" : "Create patch")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.runGitCommand(command: command, args: arguments)
                guard result.exitCode == 0 else {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    throw NSError(
                        domain: "Arbor.Git",
                        code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: detail]
                    )
                }
                guard !result.stdoutBytes.isEmpty else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected revision has no patch output."]
                    )
                }
                let message = commit.summary + (commit.messageBody.isEmpty ? "" : "\n\n\(commit.messageBody)")
                let patch = patchTextWithCommitMessage(result.stdout, commitMessage: message)
                guard !patch.isEmpty else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected revision has no patch output."]
                    )
                }
                if let destination {
                    try patchExportData(
                        result.stdoutBytes,
                        commitMessage: message,
                        encoding: options.encoding
                    )
                        .write(to: destination, options: .atomic)
                }
                await MainActor.run {
                    if options.copyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(patch, forType: .string)
                    }
                    self.feedbackCenter.success(
                        options.copyToClipboard ? "Patch copied" : "Patch created",
                        detail: options.copyToClipboard
                            ? commit.shortId
                            : destination?.lastPathComponent ?? ""
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        options.copyToClipboard ? "Copy patch failed" : "Create patch failed",
                        detail: errorMessage(error),
                        nextStep: "Check the selected revision and destination, then retry."
                    )
                }
            }
        }
    }
}

/// Export or copy the selected Changes Browser rows as one patch. Each group
/// is diffed against its own commit parent, then the textual patches are
/// joined only after every Git command succeeds. The action is intentionally
/// fail-closed for duplicate paths because a plain patch cannot express the
/// ordering of two revisions of the same file.
func createPatchFromLogSelection(_ records: [LogChangeRecord]) {
    createPatchFromLogSelection(records, copyToClipboard: false)
}

func copyPatchFromLogSelection(_ records: [LogChangeRecord]) {
    createPatchFromLogSelection(records, copyToClipboard: true)
}

func createPatchFromLogSelection(
    _ records: [LogChangeRecord],
    copyToClipboard: Bool
) {
    guard canCreateLogPatchSelection(records) else { return }

    let groups = logChangePatchGroups(records)
    let requests = groups.compactMap { group -> (Repository, CommitInfo, UInt32?, [String])? in
        guard let first = group.first,
              let repo = logRepository(for: first.commit) else {
            return nil
        }

        var paths: [String] = []
        var seenPaths = Set<String>()
        for record in group {
            for path in [record.change.oldPath, record.change.path].compactMap({ $0 }) {
                guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }
                paths.append(path)
            }
        }
        guard !paths.isEmpty else { return nil }
        return (repo, first.commit, first.parentIndex, paths)
    }
    guard requests.count == groups.count, !requests.isEmpty else { return }

    let firstCommit = records[0].commit
    let defaultFileName = records.count == 1
        ? "\(firstCommit.shortId).patch"
        : "selected.patch"
    let repositoryRootPaths = Set(requests.compactMap { $0.0.workdir() })
    guard !repositoryRootPaths.isEmpty else { return }
    let sharedRootPath = repositoryRootPaths.count == 1 ? repositoryRootPaths.first : nil
    let exportRootPath = sharedRootPath ?? repositoryRootPaths.sorted().first!
    let allPaths = requests.flatMap { $0.3 }

    let performExport: (PatchExportOptions) -> Void = { options in
        let destination = options.copyToClipboard
            ? nil
            : self.patchExportDestination(
                defaultFileName: defaultFileName,
                repositoryRootPath: exportRootPath
            )
        guard options.copyToClipboard || destination != nil else { return }
        PatchExportSettings.save(options, for: exportRootPath)

        self.beginFeedbackOperation(options.copyToClipboard ? "Copy patch" : "Create patch")
        Task.detached(priority: .userInitiated) {
            do {
                var patchParts: [Data] = []
                var patchTextParts: [String] = []
                for (repo, commit, parentIndex, paths) in requests {
                    guard let plannedCommand = logPatchGitCommand(
                        commit: commit,
                        parentIndex: parentIndex,
                        paths: paths
                    ), let repositoryRootPath = repo.workdir(),
                    let arguments = patchExportGitArguments(
                        baseArguments: plannedCommand.args,
                        repositoryRootPath: repositoryRootPath,
                        paths: paths,
                        options: options
                    ) else {
                        throw NSError(
                            domain: "Arbor.Git",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Selected revision, base directory, or path is no longer available."]
                        )
                    }

                    let result = try repo.runGitCommand(
                        command: plannedCommand.command,
                        args: arguments
                    )
                    guard result.exitCode == 0 else {
                        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                        throw NSError(
                            domain: "Arbor.Git",
                            code: Int(result.exitCode),
                            userInfo: [NSLocalizedDescriptionKey: detail]
                        )
                    }
                    patchParts.append(result.stdoutBytes)
                    patchTextParts.append(result.stdout)
                }

                let patchData = joinedGitPatchData(patchParts)
                let patchText = joinedGitPatchParts(patchTextParts)
                guard !patchData.isEmpty else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected changes have no patch output."]
                    )
                }
                if let destination {
                    try patchExportData(patchData, encoding: options.encoding)
                        .write(to: destination, options: .atomic)
                }
                await MainActor.run {
                    if options.copyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(patchText, forType: .string)
                    }
                    self.feedbackCenter.success(
                        options.copyToClipboard ? "Patch copied" : "Patch created",
                        detail: options.copyToClipboard
                            ? "\(records.count) selected change(s)"
                            : "\(records.count) selected change(s) → \(destination?.lastPathComponent ?? "")"
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        options.copyToClipboard ? "Copy patch failed" : "Create patch failed",
                        detail: errorMessage(error),
                        nextStep: "Check the selected revisions and destination, then retry."
                    )
                }
            }
        }
    }

    if copyToClipboard {
        performExport(PatchExportOptions(
            baseDirectory: nil,
            reverse: false,
            copyToClipboard: true,
            encoding: PatchExportSettings.encoding(for: exportRootPath)
        ))
    } else {
        presentPatchExportDialog(
            title: "Create Selected Patch",
            defaultFileName: defaultFileName,
            repositoryRootPath: exportRootPath,
            paths: allPaths,
            allowsBaseDirectory: sharedRootPath != nil,
            onExport: performExport
        )
    }
}

}
