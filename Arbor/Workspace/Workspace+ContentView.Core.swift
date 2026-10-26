import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func rewordUndoRequest(
    rootPath: String,
    context: PersistedRewordUndo
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .undoRewordCommit,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        rewordUndo: context
    )
}

func handleContentViewAppear() {
    DiagnosticsLogger.shared.record(
        operation: "app",
        repositoryPath: projectWorkspace.path,
        code: projectWorkspace.path == nil ? "launch-no-project" : "launch-with-project"
    )
    // Rebased keeps the Log workspace paired directly with Commit/Stash. The
    // Project surface is opened from the activity rail, so it must not steal
    // vertical space from the left Git workspace on launch.
    if projectWorkspace.toolWindowMode == .log {
        projectPanelExpanded = false
    }
    commitWorkspace.beforeCommitCommands = loadBeforeCommitCommands()
    loadMergeDialogSettings(for: projectWorkspace.path)
    loadRebaseDialogSettings(for: projectWorkspace.path)
    gitSettings.projectIncomingCheckStrategyRaw = GitIncomingCheckStrategySettings.projectRawValue(for: projectWorkspace.path)
    gitSettings.projectFetchTagsMode = GitFetchTagsSettings.mode(for: projectWorkspace.path)
    gitSettings.projectUpdateMethod = GitUpdateMethodSettings.method(for: projectWorkspace.path)
    logBranchesPanel.selectionActionRaw = GitBranchesPopupSettings.stringValue(
        GitBranchesPopupSettings.logSelectionActionKey,
        for: projectWorkspace.path
    )
    logBranchesPanel.groupByDirectory = GitBranchesPopupSettings.value(
        GitBranchesPopupSettings.groupByDirectoryKey,
        for: projectWorkspace.path
    )
    logBranchesPanel.groupByRepository = GitBranchesPopupSettings.value(
        GitBranchesPopupSettings.groupByRepositoryKey,
        for: projectWorkspace.path
    )
    loadProjectProtectedBranchSettings(for: projectWorkspace.path)
    gitSettings.identityAuthorName = UserDefaults.standard.string(forKey: "arbor.identity.authorName") ?? ""
    gitSettings.identityAuthorEmail = UserDefaults.standard.string(forKey: "arbor.identity.authorEmail") ?? ""
    gitSettings.identityRecentAuthors = GitCommitAuthorHistorySettings.authors(for: projectWorkspace.path)
    gitSettings.identityCommitterName = UserDefaults.standard.string(forKey: "arbor.identity.committerName") ?? ""
    gitSettings.identityCommitterEmail = UserDefaults.standard.string(forKey: "arbor.identity.committerEmail") ?? ""
    gitSettings.identitySignOff = GitSignOffCommitSettings.value(for: projectWorkspace.path)
    gitSettings.identityCoAuthors = UserDefaults.standard.string(forKey: "arbor.identity.coAuthors") ?? ""
    // WindowGroup/AppKit restoration can materialize ContentView with its
    // initial @State before the recent-project value has been restored. Do the
    // same recovery at the lifecycle boundary as well, otherwise the shell
    // remains on Arbor's welcome page even though the recent-project list
    // contains a valid repository (the screenshot state that looks unlike
    // rebased's project workspace).
    if projectWorkspace.repository == nil {
        let recoveredPath = projectWorkspace.path ?? ContentView.recentProjectPath()
        if projectWorkspace.path == nil, let recoveredPath {
            self.projectWorkspace.path = recoveredPath
            self.projectWorkspace.inputPath = recoveredPath
        }
        guard let recoveredPath else { return }
        DiagnosticsLogger.shared.record(
            operation: "project",
            repositoryPath: recoveredPath,
            code: "requested"
        )
        openProjectPath(recoveredPath)
    }
}

/// 文件夹选择器：NSOpenPanel 选目录后填入 path 并打开（C1）。
func showOpenPanel() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "打开项目"
    // 默认定位到当前项目或用户主目录
    if let projectPath = projectWorkspace.path {
        panel.directoryURL = URL(fileURLWithPath: projectPath)
    }
    if panel.runModal() == .OK, let url = panel.url {
        requestOpenProject(url.standardizedFileURL.path)
    }
}

/// 选择一个已有目录并初始化 Git 元数据。
func showInitializePanel() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "初始化 Git"
    if let projectPath = projectWorkspace.path {
        panel.directoryURL = URL(fileURLWithPath: projectPath)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    initializeProject(at: url.standardizedFileURL.path)
}

func loadRecentPaths() -> [String] {
    UserDefaults.standard.stringArray(forKey: "lastOpenedPaths") ?? []
}

func rememberRecentPath(_ path: String) {
    var paths = loadRecentPaths().filter { $0 != path }
    paths.insert(path, at: 0)
    UserDefaults.standard.set(Array(paths.prefix(8)), forKey: "lastOpenedPaths")
}

/// IntelliJ's GitUpdateInfoAsLog is shared by Update Project, Push, and
/// force-pushed branch updates. Keep the setting/range gate in one place so
/// every successful producer opens the same dedicated Update Info tab.
func autoOpenUpdateInfoIfEnabled(_ ranges: [PersistedLogRevisionRange]) {
    guard GitUpdateInfoAutoOpenSettings.shouldAutoOpen(ranges: ranges) else { return }
    showLogRevisionRanges(ranges)
}

func copyRepositoryRelativePath(_ path: String) {
    guard let normalized = normalizedRepositoryRelativePath(path) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(normalized, forType: .string)
    feedbackCenter.success("Path copied", detail: normalized)
}

func showInFinder(_ repo: Repository) {
    guard let workdir = repo.workdir() else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workdir)])
}

func loadGitCredentialHelpers() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        let credentialHelpers = (try? repo.credentialHelpers()) ?? []
        await MainActor.run {
            guard self.projectWorkspace.repository === repo else { return }
            self.gitSettings.gitCredentialHelpers = credentialHelpers
        }
    }
}

@MainActor

/// 逐行暂存入口：选中文件并让 diff 视图进入选择模式。
func partialMode(_ p: String) {
    fileWorkspace.previewPath = p
    fileWorkspace.selectionModePath = p
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.previewVisible = false
}

/// 加载提交信息模板（commit.template）填入提交信息框。
func loadTemplate() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        let tpl = (try? repo.commitTemplate()) ?? nil
        await MainActor.run {
            if let tpl, !tpl.isEmpty {
                self.commitWorkspace.message = tpl
            } else {
                self.commitWorkspace.feedback = "未配置提交模板"
            }
        }
    }
}

/// IDX-001「Exclude」入口：追加路径到 .git/info/exclude（不入库）。
func excludePathFromRepo(_ path: String) {
    guard let repo else { return }
    beginFeedbackOperation("Exclude path")
    Task.detached(priority: .userInitiated) {
        do {
            let rule = try repo.excludePath(path: path)
            await MainActor.run {
                self.feedbackCenter.success("Excluded", detail: "\(rule) -> .git/info/exclude")
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Exclude failed", detail: errorMessage(error), nextStep: "路径必须是非空单行。")
            }
        }
    }
}

/// Open the repository-local exclude file without exposing Git internals in
/// the view layer. This is the companion to the existing Exclude action.
func editGitExclude() {
    guard let repo else { return }
    let path = repositoryGitExcludeURL(
        gitDirectory: URL(fileURLWithPath: repo.gitDir())
    )
    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path.path) {
        FileManager.default.createFile(atPath: path.path, contents: nil)
    }
    NSWorkspace.shared.open(path)
}

/// IntelliJ's UpdateSession reports the number of files touched by the
/// received range. Keep the calculation outside RootOperationResult so the
/// generic multi-root operation record remains source-compatible; if any
/// root cannot resolve its saved range, omit the count instead of showing a
/// misleading partial number.
nonisolated static func updateSessionUpdatedFilesCount(
    _ ranges: [PersistedLogRevisionRange]
) -> Int? {
    guard !ranges.isEmpty else { return 0 }
    var total = 0
    for range in ranges {
        guard let rootRepo = try? openRepository(path: range.rootPath),
              let changes = try? rootRepo.treeChanges(
                  rev1: range.oldRevision,
                  rev2: range.newRevision
              ) else {
            return nil
        }
        total += changes.count
    }
    return total
}

func parseCoAuthors(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

nonisolated func errorMessage(_ error: Error) -> String {
    if let e = error as? EngineError {
        switch e {
        case .NotARepository(let p): return "不是 git 仓库：\(p)"
        case .GitOperation(let m): return m
        case .NoUpstream(let branch):
            return "分支 \(branch) 没有配置 upstream。请先设置远程跟踪分支，再重试 pull。"
        case .TrackingMissing(let branch, let upstream):
            return "分支 \(branch) 的远程跟踪分支 \(upstream) 不存在。请先 Fetch，或重新配置 upstream。"
        case .UntrackedWouldBeOverwritten(let paths):
            return "远程更新与本地文件路径重叠：\(paths.joined(separator: ", "))。这些文件不会被 Add 或 Commit，Arbor 会先临时保存它们并重试 pull。"
        case .LocalChangesWouldBeOverwritten(let paths):
            return "本地变更会被覆盖：\(paths.joined(separator: ", "))。请先临时保存本地变更，再重试该 Git 操作。"
        case .StashApplyConflict(let paths, _):
            return "恢复本地变更时发生冲突：\(paths.joined(separator: ", "))。请在 Merge Revisions 中解决后完成操作。"
        case .ShelveApplyConflict(let name, let paths):
            return "Shelf \(name) 应用时发生冲突：\(paths.joined(separator: ", "))。请在 Merge Revisions 中解决后完成操作。"
        case .PushRejected(let kind, let remote, let branch, let message):
            switch kind {
            case .nonFastForward:
                return "Push 被拒绝：\(remote)/\(branch) 有远程更新。请先用 Merge 或 Rebase 更新，再重试 Push。\n\(message)"
            case .noUpstream:
                return "Push 目标没有 upstream：\(remote)/\(branch)。请选择 Publish Branch / set upstream 后重试。\n\(message)"
            case .authentication:
                return "Push 认证失败：\(message)"
            case .permission:
                return "Push 权限不足：\(message)"
            case .staleInfo:
                return "Push 被 force-with-lease 拒绝：远程分支已发生变化。请确认远程历史后选择 Force Push Anyway，或先 Fetch 再重试。\n\(message)"
            case .other:
                return message
            }
        case .Cancelled:
            return "操作已取消"
        }
    }
    return "\(error)"
}

func treeChangeKindText(_ kind: TreeChangeKind) -> String {
    switch kind {
    case .added: return "新增"
    case .modified: return "修改"
    case .deleted: return "删除"
    case .renamed: return "重命名"
    }
}

}
