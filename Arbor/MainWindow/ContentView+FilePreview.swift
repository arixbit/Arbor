import SwiftUI
import AppKit

extension ContentView {

    var hasStaged: Bool { repositoryStatus.entries.contains { $0.staged != .unchanged } }
    var hasLocalChanges: Bool {
        repositoryStatus.entries.contains {
            $0.staged != .unchanged || $0.unstaged != .unchanged
        }
    }
    /// 未暂存组：unstaged 维度有变更（含冲突文件，冲突显示在 unstaged 维度）
    var unstagedEntries: [FileEntry] {
        repositoryStatus.entries.filter {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }
    var untrackedEntries: [FileEntry] {
        repositoryStatus.entries.filter { $0.unstaged == .untracked }
    }
    /// Rebased-style pull preserves the complete local workspace, including
    /// files that Git has not started tracking yet.
    var hasTrackedChanges: Bool {
        repositoryStatus.entries.contains {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged
                    && $0.unstaged != .untracked
                    && $0.unstaged != .ignored)
        }
    }
    /// Local-only files are also preserved by the pull workflow. This keeps
    /// the operation entirely automatic instead of waiting for the engine to
    /// discover a remote path collision after the pull has already started.
    var hasUntrackedOrIgnoredFiles: Bool {
        repositoryStatus.entries.contains { $0.unstaged == .untracked || $0.unstaged == .ignored }
    }
    /// 已暂存组：staged 维度有变更
    var stagedEntries: [FileEntry] { repositoryStatus.entries.filter { $0.staged != .unchanged } }
    var selectedEntry: FileEntry? {
        guard let selection = fileWorkspace.selection else { return nil }
        return repositoryStatus.entries.first { $0.path == selection }
    }
    var selectedEntryIsConflicted: Bool {
        guard let selectedEntry else { return false }
        return selectedEntry.staged == .conflicted || selectedEntry.unstaged == .conflicted
    }
    var selectedLocalChangePath: String? {
        // `restore --source HEAD --staged --worktree` is only valid when the
        // selected path exists in HEAD. Until the asynchronous staging model
        // has supplied that fact, keep the destructive main-menu action off.
        guard !shelfWorkspace.isWorkspaceTabActive, repositoryStatus.stagingModel != nil else { return nil }
        return arborSelectedRevertPath(
            entries: repositoryStatus.entries,
            candidates: [fileWorkspace.previewPath, fileWorkspace.selection, fileWorkspace.fileSelection],
            headPresentByPath: stagingPresenceByPath.mapValues(\.head)
        )
    }
    var selectedWorkspacePath: String? {
        guard !shelfWorkspace.isWorkspaceTabActive else { return nil }
        return [fileWorkspace.previewPath, fileWorkspace.selection, fileWorkspace.fileSelection]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
    var selectedFileActionContext: ArborSelectedGitFileContext? {
        guard let selectedPath = selectedWorkspacePath,
              let normalizedPath = normalizedRepositoryRelativePath(selectedPath),
              let primaryRootPath = repo?.workdir(),
              !primaryRootPath.isEmpty else { return nil }

        let isDirectory: Bool
        if selectedPath == fileWorkspace.fileSelection, let projectPath = projectWorkspace.path {
            var directory = ObjCBool(false)
            _ = FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: projectPath)
                    .appendingPathComponent(normalizedPath)
                    .path,
                isDirectory: &directory
            )
            isDirectory = directory.boolValue
        } else {
            isDirectory = false
        }

        let roots: [GitRootInfo]
        if !multiRootWorkspace.roots.isEmpty {
            roots = multiRootWorkspace.roots
        } else {
            roots = [GitRootInfo(
                path: primaryRootPath,
                displayName: URL(fileURLWithPath: primaryRootPath).lastPathComponent,
                relativePath: ".",
                isSubmodule: false,
                headBranch: currentBranchName,
                headId: repositoryStatus.headId,
                dirty: hasLocalChanges,
                operation: operationRecovery.operation?.kind
            )]
        }
        guard let target = fileReferenceComparisonTarget(
            path: normalizedPath,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else { return nil }

        let matchingEntries = repositoryStatus.entries.filter { $0.path == normalizedPath }
        let statuses = matchingEntries.flatMap { [$0.staged, $0.unstaged] }
        let hasConflict = statuses.contains(.conflicted)
        let hasIgnored = statuses.contains(.ignored)
        let hasChange = statuses.contains {
            $0 != .unchanged && $0 != .ignored
        }
        let hasUntracked = matchingEntries.contains { $0.unstaged == .untracked }
        let isPrimaryRoot = canonicalExternalLogPath(target.rootPath)
            == canonicalExternalLogPath(primaryRootPath)

        return ArborSelectedGitFileContext(
            path: normalizedPath,
            rootRelativePath: target.relativePath,
            isDirectory: isDirectory,
            owningRootPath: target.rootPath,
            isPrimaryRoot: isPrimaryRoot,
            canCheckin: isPrimaryRoot && !isDirectory && hasChange && !hasConflict,
            canAdd: !isDirectory && hasUntracked && !hasIgnored && !hasConflict,
            canAnnotate: isPrimaryRoot
                && !isDirectory
                && projectFileTreeCanAnnotate(path: normalizedPath, entries: repositoryStatus.entries),
            canCompareWithHead: !isDirectory
                && projectFileTreeCanCompareWithSameVersion(
                    path: normalizedPath,
                    entries: repositoryStatus.entries
                ),
            canCompareWithSelectedRevision: !isDirectory
                && projectFileTreeCanCompareWithSelectedRevision(
                    path: normalizedPath,
                    isDirectory: false,
                    entries: repositoryStatus.entries
                )
        )
    }

    func selectChangedFile(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        // GitStagePanel separates selection from the Show Diff Preview action.
        // Changing a row updates an already-open preview, but does not
        // silently reopen a preview the user explicitly hid.
    }

    func previewChangedFile(_ path: String) {
        // GitStagePanel reserves double-click/Enter for Open Source. Arbor has
        // no IDE editor. When Log owns the editor workspace, preserve that
        // workspace and keep the source action inside the Commit/Stash side
        // instead of replacing the selected history with a file viewer.
        if projectWorkspace.toolWindowMode == .log {
            fileWorkspace.previewPath = path
            fileWorkspace.previewComparisonMode = nil
            fileWorkspace.previewThreeVersions = false
            fileWorkspace.version = .local
            fileWorkspace.selectionModePath = nil
            fileWorkspace.selection = nil
            fileWorkspace.fileSelection = nil
            fileWorkspace.previewVisible = true
            feedbackCenter.warning(
                "Open Source is not an IDE editor",
                detail: "The Commit/Stash preview remains open so Git Log is not replaced.",
                nextStep: "Use the single-click diff or open the file from Project."
            )
            return
        }
        fileWorkspace.previewPath = nil
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selection = nil
        fileWorkspace.selectionModePath = nil
        fileWorkspace.fileSelection = path
        fileWorkspace.version = .local
        fileWorkspace.previewVisible = false
    }

    func previewFirstChangedFile() {
        if fileWorkspace.previewVisible {
            fileWorkspace.previewVisible = false
            fileWorkspace.previewThreeVersions = false
            return
        }
        fileWorkspace.previewPath = repositoryStatus.entries.first(where: {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        })?.path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.previewVisible = true
    }

    func showCommitDiffPreview(_ path: String) {
        // This is the stage-tree equivalent of Git.Stage.Tree.Menu's
        // Diff.ShowDiff action. It deliberately does not enter the editor
        // file-selection path: when Log is active, the right workspace must
        // remain the graph/details inspector and the diff belongs beside the
        // Commit/Stash tree on the left.
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewMode = .unstaged
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    func showCommitStagedDiffPreview(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewMode = .staged
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    func showCommitLocalStagedDiffPreview(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = stagingComparisonDiffMode(for: .localWithStaged)
        fileWorkspace.previewMode = .unstaged
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    func showCommitThreeVersionsPreview(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = true
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    func showCommitLocalVersion(_ path: String) {
        showCommitFileVersion(path, version: .local)
    }

    func showCommitStagedVersion(_ path: String) {
        showCommitFileVersion(path, version: .staged)
    }

    private func showCommitFileVersion(_ path: String, version: FileContentVersion) {
        fileWorkspace.previewPath = nil
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewVisible = false
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.treeDiffRequest = nil
        fileWorkspace.selection = nil
        fileWorkspace.selectionModePath = nil
        fileWorkspace.version = version
        fileWorkspace.fileSelection = path
    }

    func annotateProjectFile(_ path: String) {
        guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return }
        projectWorkspace.toolWindowMode = .commit
        fileWorkspace.treeDiffRequest = nil
        fileWorkspace.selection = nil
        fileWorkspace.selectionModePath = nil
        logSelectionState.selection = nil
        fileWorkspace.version = .local
        fileWorkspace.fileSelection = normalizedPath
        fileWorkspace.blameRequestID &+= 1
    }

    /// IDX-001 二进制文件路径集合（staging model 提供）。
    var stagingBinaryPaths: Set<String> {
        Set((repositoryStatus.stagingModel?.entries ?? []).filter { $0.binary }.map { $0.path })
    }

    /// IDX-001: expose exact HEAD/index/worktree presence to Changes actions;
    /// status kinds alone cannot distinguish an empty file from a missing side.
    var stagingPresenceByPath: [String: StagingVersionPresence] {
        Dictionary(
            uniqueKeysWithValues: (repositoryStatus.stagingModel?.entries ?? []).map { entry in
                (entry.path, stagingVersionPresence(for: entry))
            }
        )
    }

    var fileContentVersionOptions: [FileContentVersion] {
        guard let path = fileWorkspace.fileSelection,
              let entry = repositoryStatus.entries.first(where: { $0.path == path }) else {
            return [fileWorkspace.version]
        }
        return fileContentVersions(
            for: stagingVersionActions(
                for: entry,
                presence: stagingPresenceByPath[path]
            ),
            current: fileWorkspace.version
        )
    }
}
