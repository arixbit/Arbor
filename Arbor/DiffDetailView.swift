import SwiftUI
import AppKit

// MARK: - 详情：diff（状态模式，含冲突路由）

/// 逐行选择：hunk 下标 + old/new 两侧绝对行号（1-based）。纯新增行
/// 没有 old 行号，因此由 newLine 表示。
struct SelectedDiffLine: Hashable {
    let hunkIndex: Int
    let oldLine: UInt32
    var newLine: UInt32 = 0
}

/// 把 UI 选择转换成引擎的逐 hunk 两侧行号集合。
func makeLineSelections(from selectedLines: Set<SelectedDiffLine>) -> [LineSelection] {
    var groups: [Int: (old: [UInt32], new: [UInt32])] = [:]
    for line in selectedLines {
        if line.oldLine > 0 {
            groups[line.hunkIndex, default: (old: [], new: [])].old.append(line.oldLine)
        }
        if line.newLine > 0 {
            groups[line.hunkIndex, default: (old: [], new: [])].new.append(line.newLine)
        }
    }
    return groups.keys.sorted().map { idx in
        let group = groups[idx]!
        return LineSelection(
            hunkIndex: UInt32(idx),
            oldLines: group.old.sorted(),
            newLines: group.new.sorted()
        )
    }
}

/// Prevents a cancelled or superseded diff read from replacing a newer view
/// for the same path.
func isCurrentDiffRequest(
    path: String,
    generation: Int,
    currentPath: String?,
    currentGeneration: Int
) -> Bool {
    path == currentPath && generation == currentGeneration
}

/// Shared settings for every structured Git file-diff entry point. The
/// external conversion preference is global in Settings, so background views
/// such as Log and Shelf can use the same explicit opt-in without duplicating
/// state plumbing.
func makeArborGitDiffSettings(ignoreWhitespace: Bool = false) -> DiffSettings {
    DiffSettings(
        ignoreWhitespaceAtEol: false,
        ignoreAllSpace: ignoreWhitespace,
        wordDiff: false,
        crlfSensitive: true,
        useExternalTextconv: UserDefaults.standard.bool(
            forKey: "arbor.git.externalConversion.v1"
        )
    )
}

enum ThreeVersionComparisonMode: String, CaseIterable, Identifiable {
    case overview
    case headToStaged
    case stagedToLocal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "3 Versions"
        case .headToStaged: "HEAD → Staged"
        case .stagedToLocal: "Staged → Local"
        }
    }

    var diffMode: DiffMode? {
        switch self {
        case .overview: nil
        case .headToStaged: .indexToHead
        case .stagedToLocal: .worktreeToIndex
        }
    }

    var stagingMode: StagingPreviewMode? {
        switch self {
        case .overview: nil
        case .headToStaged: .staged
        case .stagedToLocal: .unstaged
        }
    }
}

/// The raw Git command used by Diff Viewer patch export. Keeping this as a
/// value type makes the action testable without constructing a SwiftUI view,
/// and keeps revisions/paths as separate argv elements all the way to Git.
struct DiffPatchGitCommand: Equatable {
    let command: String
    let args: [String]
    let acceptsExitCodeOne: Bool
}

/// Builds the Git command used by the user-visible external Diff action.
/// Unlike patch export, this deliberately keeps Git's configured difftool in
/// the loop; the tool itself owns the two temporary/revision endpoints.
struct DiffExternalGitCommand: Equatable {
    let command: String
    let args: [String]
}

private func uniqueDiffPatchPaths(for entry: FileEntry) -> [String]? {
    var paths: [String] = []
    var seen = Set<String>()
    for path in [entry.oldPath, entry.path].compactMap({ $0 }) {
        guard !path.isEmpty, seen.insert(path).inserted else { continue }
        paths.append(path)
    }
    return paths.isEmpty ? nil : paths
}

/// Builds a portable patch command for a status Diff Viewer comparison.
/// Untracked files need `--no-index`; Git intentionally returns exit code 1
/// for that command when the two sides differ, which the caller accepts.
func diffPatchGitCommand(for entry: FileEntry, mode: DiffMode) -> DiffPatchGitCommand? {
    guard let paths = uniqueDiffPatchPaths(for: entry) else { return nil }
    let common = ["--no-color", "--binary", "--no-ext-diff"]

    switch mode {
    case .worktreeToIndex:
        if entry.unstaged == .untracked {
            guard paths.count == 1 else { return nil }
            return DiffPatchGitCommand(
                command: "diff",
                args: common + ["--no-index", "--", "/dev/null", paths[0]],
                acceptsExitCodeOne: true
            )
        }
        return DiffPatchGitCommand(
            command: "diff",
            args: common + ["--"] + paths,
            acceptsExitCodeOne: false
        )
    case .indexToWorktree:
        if entry.unstaged == .untracked {
            guard paths.count == 1 else { return nil }
            return DiffPatchGitCommand(
                command: "diff",
                args: common + ["--no-index", "--", paths[0], "/dev/null"],
                acceptsExitCodeOne: true
            )
        }
        return DiffPatchGitCommand(
            command: "diff",
            args: common + ["--reverse", "--"] + paths,
            acceptsExitCodeOne: false
        )
    case .indexToHead:
        return DiffPatchGitCommand(
            command: "diff",
            args: common + ["--cached", "--"] + paths,
            acceptsExitCodeOne: false
        )
    case .worktreeToHead:
        return DiffPatchGitCommand(
            command: "diff",
            args: common + ["HEAD", "--"] + paths,
            acceptsExitCodeOne: false
        )
    }
}

/// Builds a patch command for the standalone revision comparison fields.
/// Revision tokens are deliberately restricted to ref-like values so a user
/// cannot turn a text field into an option before the `--` path separator.
func diffPatchGitCommand(
    revision1: String,
    revision2: String,
    path: String
) -> DiffPatchGitCommand? {
    let first = revision1.trimmingCharacters(in: .whitespacesAndNewlines)
    let second = revision2.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !first.isEmpty,
          !second.isEmpty,
          !first.hasPrefix("-"),
          !second.hasPrefix("-"),
          first.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          second.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          !path.isEmpty else { return nil }
    return DiffPatchGitCommand(
        command: "diff",
        args: ["--no-color", "--binary", "--no-ext-diff", first, second, "--", path],
        acceptsExitCodeOne: false
    )
}

/// Builds a non-interactive `git difftool` invocation for the active two-side
/// comparison. Revision/path tokens remain separate argv values and the `--`
/// separator is always present before paths, so filenames cannot become Git
/// options. Three-version, blame, and clipboard views intentionally do not
/// use this helper because they are not a single two-side Git comparison.
func externalDiffGitCommand(
    for entry: FileEntry,
    mode: DiffMode
) -> DiffExternalGitCommand? {
    guard let paths = uniqueDiffPatchPaths(for: entry) else { return nil }
    let prefix = ["--no-prompt"]

    switch mode {
    case .worktreeToIndex:
        if entry.unstaged == .untracked {
            guard paths.count == 1 else { return nil }
            return DiffExternalGitCommand(
                command: "difftool",
                args: prefix + ["--no-index", "--", "/dev/null", paths[0]]
            )
        }
        return DiffExternalGitCommand(
            command: "difftool",
            args: prefix + ["--"] + paths
        )
    case .indexToWorktree:
        if entry.unstaged == .untracked {
            guard paths.count == 1 else { return nil }
            return DiffExternalGitCommand(
                command: "difftool",
                args: prefix + ["--no-index", "--", paths[0], "/dev/null"]
            )
        }
        return DiffExternalGitCommand(
            command: "difftool",
            args: prefix + ["--reverse", "--"] + paths
        )
    case .indexToHead:
        return DiffExternalGitCommand(
            command: "difftool",
            args: prefix + ["--cached", "--"] + paths
        )
    case .worktreeToHead:
        return DiffExternalGitCommand(
            command: "difftool",
            args: prefix + ["HEAD", "--"] + paths
        )
    }
}

/// Resolve the explicit Git difftool selector without opening Git's first-run
/// interactive picker. The repository's local config and inherited config are
/// both visible through `git config --get`.
func configuredExternalDiffToolName(
    diffTool: GitCommandResult,
    guiTool: GitCommandResult
) -> String? {
    [diffTool, guiTool].first { result in
        result.exitCode == 0
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func configuredExternalDiffTool(repo: Repository) throws -> String {
    let diffTool = (try? repo.runGitCommand(command: "config", args: ["--get", "diff.tool"]))
        ?? GitCommandResult(command: "git config --get diff.tool", stdout: "", stdoutBytes: Data(), stderr: "", exitCode: 1, durationMs: 0)
    let guiTool = (try? repo.runGitCommand(command: "config", args: ["--get", "diff.guitool"]))
        ?? GitCommandResult(command: "git config --get diff.guitool", stdout: "", stdoutBytes: Data(), stderr: "", exitCode: 1, durationMs: 0)
    if let tool = configuredExternalDiffToolName(diffTool: diffTool, guiTool: guiTool) {
        return tool
    }
    throw NSError(
        domain: "Arbor.Git",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey:
            "No Git diff.tool or diff.guitool is configured. Configure a difftool in Git settings, then retry."]
    )
}

struct DiffDetailView: View {
    let repo: Repository?
    let entry: FileEntry?
    let onChanged: () -> Void
    /// 侧栏「逐行」入口：等于当前文件路径时自动开启选择模式
    let selectionModePath: String?
    /// Staging preview supplies the active dimension so entering line mode
    /// does not silently switch a staged diff back to the worktree side.
    var initialMode: DiffMode? = nil
    /// Invalidates the diff after a visible status/index refresh.
    var refreshToken: Int = 0

    @State private var mode: DiffMode = .worktreeToIndex
    @State private var fileDiff: FileDiff?
    @State private var diffError: String?
    @AppStorage("arbor.git.externalConversion.v1") private var gitExternalConversionEnabled = false
    @State private var ignoreWhitespace = false
    @State private var wordDiff = false
    @State private var crlfSensitive = true
    @State private var rev1: String = ""
    @State private var rev2: String = ""
    @State private var showBlame = false
    @State private var showThreeVersions = false
    @State private var blameLines: [BlameLine] = []
    @State private var showAttributes = false
    @State private var fileAttributes: FileAttributes?
    @State private var effectiveLineEndings: EffectiveLineEndings?
    @State private var attributesError: String?
    @State private var presentationMode: DiffPresentationMode = .sideBySide
    // 逐行暂存选择模式
    @State private var selectionMode = false
    @State private var selectedLines: Set<SelectedDiffLine> = []
    @State private var hunkTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var patchPlan: DiffPatchGitCommand?
    @State private var patchExportRequest: PatchExportRequest?
    @State private var externalDiffCancelHandle: GitCancelHandle?
    @State private var externalDiffWorking = false
    @State private var externalDiffCancelling = false

    private var isConflicted: Bool {
        entry?.staged == .conflicted || entry?.unstaged == .conflicted
    }
    private var hasUnstaged: Bool { entry?.unstaged != .unchanged }
    private var hasStaged: Bool { entry?.staged != .unchanged }
    private var isReadOnlyComparison: Bool {
        initialMode == .indexToWorktree || initialMode == .worktreeToHead
    }
    private var canExportPatch: Bool {
        guard !showBlame, !showThreeVersions, patchPlan != nil, let fileDiff else { return false }
        return fileDiff.binary || !fileDiff.hunks.isEmpty
    }
    private var stagingModeForHunkActions: StagingPreviewMode? {
        guard !isReadOnlyComparison else { return nil }
        switch mode {
        case .worktreeToIndex: return .unstaged
        case .indexToHead: return .staged
        case .indexToWorktree, .worktreeToHead: return nil
        }
    }

    var body: some View {
        Group {
            if let entry {
                if isConflicted {
                    ConflictDetailView(repo: repo, path: entry.path, onChanged: onChanged)
                } else {
                    VStack(spacing: 0) {
                        header(entry)
                        Divider()
                        if showThreeVersions {
                            ThreeVersionComparisonView(
                                repo: repo,
                                path: entry.path,
                                entry: entry,
                                refreshToken: refreshToken,
                                onChanged: onChanged,
                                onClose: {
                                    showThreeVersions = false
                                    load()
                                }
                            )
                        } else if showBlame {
                            blameView(entry.path)
                        } else {
                            content
                        }
                    }
                }
            } else {
                Text("选择一个文件查看 diff / 冲突")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let initialMode {
                mode = initialMode
            }
            if isReadOnlyComparison {
                selectionMode = false
                selectedLines.removeAll()
            }
            if !isReadOnlyComparison && selectionModePath == entry?.path {
                selectionMode = true
            }
            if entry != nil && !isConflicted { load() }
        }
        .onChange(of: entry) { _, _ in
            fileDiff = nil
            patchPlan = nil
            showAttributes = false
            fileAttributes = nil
            effectiveLineEndings = nil
            attributesError = nil
            selectedLines.removeAll()
            if entry != nil && !isConflicted { load() }
        }
        .onChange(of: refreshToken) { _, _ in load() }
        .onChange(of: mode) { _, _ in
            selectedLines.removeAll()
            load()
        }
        .onChange(of: selectionModePath) { _, p in
            if p == entry?.path {
                selectionMode = true
                if let initialMode {
                    mode = initialMode
                }
            }
        }
        .onChange(of: initialMode) { _, newMode in
            if newMode == .indexToWorktree {
                selectionMode = false
                selectedLines.removeAll()
            }
            if let newMode,
               (selectionModePath == entry?.path || isReadOnlyComparison) {
                mode = newMode
            }
        }
        .onDisappear {
            loadGeneration &+= 1
            externalDiffCancelHandle?.cancel()
            hunkTask?.cancel()
        }
    }

    private func header(_ entry: FileEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(entry.path).font(.headline).lineLimit(1)
                Spacer()
                Toggle("忽略空白", isOn: $ignoreWhitespace)
                    .toggleStyle(.checkbox)
                    .onChange(of: ignoreWhitespace) { _, _ in load() }
                Toggle("Word Diff", isOn: $wordDiff)
                    .toggleStyle(.checkbox)
                    .onChange(of: wordDiff) { _, _ in load() }
                Toggle("CRLF 敏感", isOn: $crlfSensitive)
                    .toggleStyle(.checkbox)
                    .onChange(of: crlfSensitive) { _, _ in load() }
                if !isReadOnlyComparison {
                    Toggle("选择模式", isOn: $selectionMode)
                        .toggleStyle(.checkbox)
                        .onChange(of: selectionMode) { _, on in
                            if !on { selectedLines.removeAll() }
                        }
                }
                Menu("Patch") {
                    Button("Create Patch…") { exportPatch(copyToClipboard: false) }
                    Button("Copy Patch") { exportPatch(copyToClipboard: true) }
                }
                .disabled(!canExportPatch)
                Button(externalDiffWorking
                       ? (externalDiffCancelling ? "Canceling…" : "Cancel External Diff")
                       : "External Diff") {
                    if externalDiffWorking {
                        cancelExternalDiff()
                    } else {
                        openExternalDiff()
                    }
                }
                .disabled(externalDiffWorking
                          ? externalDiffCancelling
                          : showBlame || showThreeVersions || externalDiffGitCommand(for: entry, mode: mode) == nil)
                    .help("Open the active comparison in Git's configured difftool")
                if showBlame {
                    GitAnnotationOptionsMenu {
                        loadBlame(entry.path)
                    }
                }
                Button("与剪贴板比较") {
                    patchPlan = nil
                    compareWithClipboard(entry.path)
                }
                Button("Attributes") {
                    showAttributes = true
                    loadAttributes(entry.path)
                }
                Button(showBlame ? "Diff" : "Blame") {
                    showBlame.toggle()
                    if showBlame {
                        patchPlan = nil
                        loadBlame(entry.path)
                    } else {
                        load()
                    }
                }
                Button(showThreeVersions ? "Diff" : "Compare Three Versions") {
                    showThreeVersions.toggle()
                    if showThreeVersions {
                        patchPlan = nil
                    } else {
                        load()
                    }
                }
                .disabled(isReadOnlyComparison || (!hasUnstaged && !hasStaged))
                if isReadOnlyComparison {
                    Text(initialMode == .worktreeToHead ? "HEAD → Local" : "Local → Staged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("维度", selection: $mode) {
                        Text("工作区").tag(DiffMode.worktreeToIndex)
                        Text("已暂存").tag(DiffMode.indexToHead)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .disabled(!hasUnstaged && !hasStaged)
                }
                Picker("Diff View", selection: $presentationMode) {
                    ForEach(DiffPresentationMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(selectionMode)
            }
            HStack(spacing: 6) {
                TextField("rev1", text: $rev1).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("rev2", text: $rev2).textFieldStyle(.roundedBorder).frame(width: 130)
                Button("任意版本比较") { compareRevs(entry.path) }
                    .disabled(rev1.isEmpty || rev2.isEmpty)
                Spacer()
                if selectionMode {
                    Text("点击变更行选择（变更组不可拆分）")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(selectedLines.count) 行已选")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(mode == .worktreeToIndex ? "暂存所选行" : "取消暂存所选行") { applyPartial() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedLines.isEmpty)
                }
            }
        }
        .padding(10)
        .popover(isPresented: $showAttributes, arrowEdge: .bottom) {
            FileAttributesInspector(
                attributes: fileAttributes,
                lineEndings: effectiveLineEndings,
                error: attributesError
            )
        }
        .sheet(item: $patchExportRequest) { request in
            RebasedPatchExportDialog(
                request: request,
                onExport: { options in
                    patchExportRequest = nil
                    DispatchQueue.main.async {
                        request.onExport(options)
                    }
                },
                onCancel: { patchExportRequest = nil }
            )
        }
    }

    /// 与剪贴板文本比较（读 NSPasteboard）。
    private func compareWithClipboard(_ path: String) {
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let repo, let text = NSPasteboard.general.string(forType: .string) else { return }
        let ws = ignoreWhitespace
        fileDiff = nil
        Task.detached(priority: .userInitiated) {
            do {
                let d = try repo.diffWithText(path: path, text: text, ignoreWhitespace: ws)
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.fileDiff = d
                    self.diffError = nil
                }
            } catch {
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.diffError = "\(error)"
                }
            }
        }
    }

    /// 任意两个 rev 的指定文件比较。
    private func compareRevs(_ path: String) {
        guard let repo else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let r1 = rev1, r2 = rev2, ws = ignoreWhitespace
        guard let plan = diffPatchGitCommand(revision1: r1, revision2: r2, path: path) else {
            diffError = "Revision must be a ref-like token without whitespace or a leading '-'."
            patchPlan = nil
            return
        }
        patchPlan = plan
        fileDiff = nil
        Task.detached(priority: .userInitiated) {
            do {
                let d = try repo.diffCommitsWithSettings(
                    rev1: r1,
                    rev2: r2,
                    path: path,
                    settings: makeArborGitDiffSettings(ignoreWhitespace: ws)
                )
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.fileDiff = d
                    self.diffError = nil
                }
            } catch {
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.diffError = "\(error)"
                }
            }
        }
    }

    /// Exports exactly the revision pair currently represented by the Diff
    /// Viewer. Clipboard and three-version comparisons intentionally clear
    /// `patchPlan` because their second side is not a Git revision pair.
    private func exportPatch(copyToClipboard: Bool) {
        guard let repo, let plan = patchPlan, let entry, canExportPatch,
              let repositoryRootPath = repo.workdir(),
              let paths = uniqueDiffPatchPaths(for: entry) else { return }
        let path = entry.path
        let defaultFileName = "\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).patch"
        patchExportRequest = PatchExportRequest(
            title: "Create Patch",
            defaultFileName: defaultFileName,
            repositoryRootPath: repositoryRootPath,
            paths: paths,
            allowsBaseDirectory: !plan.args.contains("--no-index"),
            initialCopyToClipboard: PatchExportSettings.copyToClipboard(for: repositoryRootPath),
            initialEncoding: PatchExportSettings.encoding(for: repositoryRootPath),
            onExport: { options in
                let destination = options.copyToClipboard
                    ? nil
                    : choosePatchExportDestination(
                        defaultFileName: defaultFileName,
                        repositoryRootPath: repositoryRootPath
                    )
                guard options.copyToClipboard || destination != nil else { return }
                PatchExportSettings.save(options, for: repositoryRootPath)
                guard let arguments = patchExportGitArguments(
                    baseArguments: plan.args,
                    repositoryRootPath: repositoryRootPath,
                    paths: paths,
                    options: options
                ) else {
                    self.diffError = "Patch export failed: the selected base directory does not contain this path."
                    return
                }

                Task.detached(priority: .userInitiated) {
                    do {
                        let result = try repo.runGitCommand(command: plan.command, args: arguments)
                        let success = result.exitCode == 0 || (plan.acceptsExitCodeOne && result.exitCode == 1)
                        guard success else {
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
                                code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "The selected comparison has no changes to export."]
                            )
                        }
                        if let destination {
                            try patchExportData(result.stdoutBytes, encoding: options.encoding)
                                .write(to: destination, options: .atomic)
                        }
                        await MainActor.run {
                            guard self.entry?.path == path else { return }
                            if options.copyToClipboard {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.stdout, forType: .string)
                            }
                            self.diffError = nil
                        }
                    } catch {
                        await MainActor.run {
                            guard self.entry?.path == path else { return }
                            self.diffError = "Patch export failed: \(error)"
                        }
                    }
                }
            }
        )
        if copyToClipboard {
            let options = PatchExportOptions(
                baseDirectory: nil,
                reverse: false,
                copyToClipboard: true,
                encoding: PatchExportSettings.encoding(for: repositoryRootPath)
            )
            PatchExportSettings.save(options, for: repositoryRootPath)
            patchExportRequest?.onExport(options)
            patchExportRequest = nil
        }
    }

    /// Run the configured Git difftool only after resolving an explicit tool
    /// name. This avoids Git's first-run interactive tool picker from blocking
    /// the SwiftUI operation indefinitely; when neither selector is set we
    /// fail closed with a settings-oriented message.
    private func openExternalDiff() {
        guard let repo,
              let entry,
              !showBlame,
              !showThreeVersions,
              !externalDiffWorking,
              let command = externalDiffGitCommand(for: entry, mode: mode) else { return }
        let path = entry.path
        let generation = loadGeneration
        let cancelHandle = GitCancelHandle()
        externalDiffCancelHandle = cancelHandle
        externalDiffWorking = true
        externalDiffCancelling = false
        diffError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let tool = try configuredExternalDiffTool(repo: repo)
                let args = ["--tool", tool] + command.args
                let result = try repo.runGitCommandWithCancel(
                    command: command.command,
                    args: args,
                    cancel: cancelHandle
                )
                guard result.exitCode == 0 else {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    throw NSError(
                        domain: "Arbor.Git",
                        code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: detail.isEmpty
                            ? "The external diff tool returned exit code \(result.exitCode)."
                            : detail]
                    )
                }
                await MainActor.run {
                    self.externalDiffWorking = false
                    self.externalDiffCancelling = false
                    self.externalDiffCancelHandle = nil
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.diffError = nil
                }
            } catch {
                await MainActor.run {
                    self.externalDiffWorking = false
                    self.externalDiffCancelling = false
                    self.externalDiffCancelHandle = nil
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.diffError = cancelHandle.isCancelled()
                        ? "External diff canceled."
                        : "External diff failed: \(error)"
                }
            }
        }
    }

    private func cancelExternalDiff() {
        guard externalDiffWorking, !externalDiffCancelling else { return }
        externalDiffCancelling = true
        externalDiffCancelHandle?.cancel()
    }

    /// HISTORY-001 收口：blame 行 -> 对应 commit detail。
    /// 通过通知切到 Log 视图并选中提交。
    private func openCommitDetail(_ commitId: String) {
        NotificationCenter.default.post(name: .arborOpenCommitDetail, object: commitId)
    }

    private func loadBlame(_ path: String) {
        guard let repo else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let lines = try repo.blameWithOptions(
                    path: path,
                    options: GitAnnotationSettings.options()
                )
                await MainActor.run { self.blameLines = lines; self.diffError = nil }
            } catch { await MainActor.run { self.diffError = "\(error)" } }
        }
    }

    /// CFG-001：展示 Git 对当前文件实际解析出的 attributes 与换行行为。
    /// 这里只读 check-attr 结果；外部 difftool 只通过上方的显式动作执行。
    private func loadAttributes(_ path: String) {
        guard let repo else { return }
        fileAttributes = nil
        effectiveLineEndings = nil
        attributesError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let attributes = try repo.fileAttributes(paths: [path]).first
                // A deleted or otherwise unavailable worktree file can still
                // have valid check-attr facts; keep those visible even when
                // effective line-ending conversion cannot be computed.
                let endings = try? repo.effectiveLineEndings(path: path)
                await MainActor.run {
                    guard self.entry?.path == path else { return }
                    self.fileAttributes = attributes
                    self.effectiveLineEndings = endings
                }
            } catch {
                await MainActor.run {
                    guard self.entry?.path == path else { return }
                    self.attributesError = "\(error)"
                }
            }
        }
    }

    /// 逐行 blame 列表。
    @ViewBuilder
    private func blameView(_ path: String) -> some View {
        if let diffError {
            Text(diffError).foregroundStyle(Design.Colors.error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if blameLines.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blameLines, id: \.line) { line in
                        HStack(spacing: 8) {
                            // 按提交着色的 gutter 块（同提交同色，确定性映射）
                            Text(line.shortId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(blameColor(line.shortId))
                                .frame(width: 60, alignment: .leading)
                                .help(blameTooltip(line))
                            Text(line.author)
                                .font(.system(.caption))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                                .lineLimit(1)
                                .help(blameTooltip(line))
                            Text(String(line.line))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(highlightedBlameText(line))
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(blameTooltip(line))
                        }
                        .padding(.vertical, 0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { openCommitDetail(line.commitId) }
                        .help("点击打开该提交详情")
                    }
                }
            }
        }
    }

    /// blame 行语法高亮（引擎 BlameLine.highlights，行内局部偏移）。
    private func highlightedBlameText(_ line: BlameLine) -> AttributedString {
        var attr = AttributedString(line.text)
        SyntaxHighlight.apply(line.highlights, to: line.text, attr: &attr)
        return attr
    }

    /// 悬浮：作者 · 摘要 · 日期。
    private func blameTooltip(_ line: BlameLine) -> String {
        "\(line.author) · \(line.summary) · \(dateStr(line.time))"
    }

    /// 按提交短 id 确定性取色（同提交行同色）。
    private func blameColor(_ shortId: String) -> Color {
        let palette: [Color] = [
            .orange, .pink, .teal, .indigo, .brown,
            .mint, .purple, .cyan, .green, .red,
        ]
        var h: UInt64 = 0
        for b in shortId.utf8 {
            h = h &* 31 &+ UInt64(b)
        }
        return palette[Int(h % UInt64(palette.count))]
    }

    @ViewBuilder
    private var content: some View {
        if let diffError {
            Text(diffError).foregroundStyle(Design.Colors.error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fileDiff {
            if fileDiff.binary {
                Text("二进制文件，无法显示 diff").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileDiff.hunks.isEmpty {
                Text("该维度无变更").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if presentationMode == .unified {
                UnifiedDiffView(fileDiff: fileDiff)
            } else {
                SideBySideDiffView(
                    fileDiff: fileDiff,
                    selectionMode: selectionMode,
                    selectedLines: selectedLines,
                    onToggleLine: toggleLine,
                    hunkActions: hunkActions(for: fileDiff),
                    hunkActionsDisabled: hunkTask != nil,
                    onHunkAction: applyHunk
                )
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 逐行暂存选择

    /// 点击行切换选中；删除从 old 侧记录，纯新增从 new 侧记录。
    private func toggleLine(_ line: SelectedDiffLine) {
        guard !isReadOnlyComparison else { return }
        if selectedLines.contains(line) {
            selectedLines.remove(line)
        } else {
            selectedLines.insert(line)
        }
    }

    /// 选中行按 hunk 分组 -> LineSelection（两侧都为空才是 hunk 级）。
    private var lineSelections: [LineSelection] {
        makeLineSelections(from: selectedLines)
    }

    /// 暂存/取消暂存所选行：WorktreeToIndex -> stageLines；IndexToHead -> unstageLines。
    private func applyPartial() {
        guard !isReadOnlyComparison else { return }
        guard let repo, let entry else { return }
        let path = entry.path
        let selections = lineSelections
        guard !selections.isEmpty else { return }
        let m = mode
        Task.detached(priority: .userInitiated) {
            do {
                if m == .worktreeToIndex {
                    try repo.stageLines(path: path, selections: selections)
                } else {
                    try repo.unstageLines(path: path, selections: selections)
                }
                await MainActor.run {
                    self.selectedLines.removeAll()
                    self.onChanged()
                    self.load()
                    self.diffError = nil
                }
            } catch {
                await MainActor.run { self.diffError = "\(error)" }
            }
        }
    }

    private func hunkActions(for diff: FileDiff) -> [DiffHunkAction] {
        guard let entry, let stagingMode = stagingModeForHunkActions else { return [] }
        return stagingHunkActions(for: entry, mode: stagingMode, diff: diff)
    }

    private func applyHunk(_ action: DiffHunkAction, _ hunkIndex: Int) {
        guard let repo,
              let entry,
              let stagingMode = stagingModeForHunkActions,
              let fileDiff,
              hunkIndex >= 0,
              hunkIndex < fileDiff.hunks.count,
              (stagingMode == .unstaged
               && (action == .stage || action == .rollback))
                  || (stagingMode == .staged && action == .unstage),
              hunkTask == nil else { return }

        let expectedPath = entry.path
        let selection = LineSelection(hunkIndex: UInt32(hunkIndex), oldLines: [], newLines: [])
        hunkTask = Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .stage:
                    try repo.stageLines(path: expectedPath, selections: [selection])
                case .unstage:
                    try repo.unstageLines(path: expectedPath, selections: [selection])
                case .rollback:
                    try repo.restoreUnstagedLines(path: expectedPath, selections: [selection])
                }
                await MainActor.run {
                    guard self.entry?.path == expectedPath else {
                        self.hunkTask = nil
                        return
                    }
                    self.hunkTask = nil
                    self.selectedLines.removeAll()
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    guard self.entry?.path == expectedPath else {
                        self.hunkTask = nil
                        return
                    }
                    self.hunkTask = nil
                    self.diffError = "\(error)"
                }
            }
        }
    }

    private func load() {
        if externalDiffWorking {
            externalDiffCancelling = true
            externalDiffCancelHandle?.cancel()
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        fileDiff = nil
        diffError = nil
        guard let repo, let entry else { return }
        if !isReadOnlyComparison && mode == .worktreeToIndex && !hasUnstaged && hasStaged {
            mode = .indexToHead
        } else if !isReadOnlyComparison && mode == .indexToHead && !hasStaged && hasUnstaged {
            mode = .worktreeToIndex
        }
        let path = entry.path
        // `onAppear` may set `mode` and call `load()` in the same transaction;
        // use the request's immutable mode directly for read-only comparisons
        // so HEAD → Local cannot briefly load the staging diff instead.
        let m = isReadOnlyComparison ? (initialMode ?? mode) : mode
        patchPlan = diffPatchGitCommand(for: entry, mode: m)
        let settings = DiffSettings(
            ignoreWhitespaceAtEol: false,
            ignoreAllSpace: ignoreWhitespace,
            wordDiff: wordDiff,
            crlfSensitive: crlfSensitive,
            useExternalTextconv: gitExternalConversionEnabled
        )
        Task.detached(priority: .userInitiated) {
            do {
                let d = try repo.diffFileWithSettings(path: path, mode: m, settings: settings)
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.fileDiff = d
                    self.diffError = nil
                }
            } catch {
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: path,
                        generation: generation,
                        currentPath: self.entry?.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.diffError = "\(error)"
                }
            }
        }
    }
}

/// 三栏 staging 对比：HEAD、index（Staged）和当前工作区（Worktree）。
/// 这是 IntelliJ GitStageCompareThreeVersionsAction 的 macOS 对应入口：
/// 三栏总览保留每一侧的真实内容，两个 pairwise 视图复用 staging hunk
/// actions，让 HEAD→Staged 可以取消暂存，Staged→Local 可以暂存或回滚。
struct ThreeVersionComparisonView: View {
    let repo: Repository?
    let path: String
    let entry: FileEntry?
    var refreshToken: Int = 0
    let onChanged: () -> Void
    let onClose: () -> Void

    @State private var displayMode: ThreeVersionComparisonMode = .overview
    @State private var versions: StagingFileVersions?
    @State private var comparison: FileDiff?
    @State private var isLoading = false
    @State private var error: String?
    @State private var comparisonError: String?
    @State private var task: Task<Void, Never>?
    @State private var mutationTask: Task<Void, Never>?
    @State private var loadGeneration = 0

    private var comparisonHunkActions: [DiffHunkAction] {
        guard let comparison, let entry, let stagingMode = displayMode.stagingMode else { return [] }
        return stagingHunkActions(for: entry, mode: stagingMode, diff: comparison)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("View", selection: $displayMode) {
                    ForEach(ThreeVersionComparisonMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 330)
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Design.Colors.surface)

            Group {
                if let error {
                    Text(error)
                        .foregroundStyle(Design.Colors.error)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                } else if isLoading && (displayMode == .overview ? versions == nil : comparison == nil) {
                    ProgressView("Loading three versions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayMode == .overview, let versions {
                    overview(versions)
                } else if displayMode != .overview {
                    comparisonContent
                } else {
                    Text("Select a changed file to compare its three versions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: displayMode) { _, _ in load() }
        .onChange(of: refreshToken) { _, _ in load() }
        .onDisappear {
            loadGeneration &+= 1
            task?.cancel()
            mutationTask?.cancel()
        }
    }

    private func overview(_ versions: StagingFileVersions) -> some View {
        HStack(spacing: 1) {
            ThreeVersionPane(title: "HEAD", content: versions.head)
            ThreeVersionPane(title: "Staged", content: versions.staged)
            ThreeVersionPane(title: "Worktree", content: versions.local)
        }
        .background(Design.Colors.surface)
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if let comparisonError {
            Text(comparisonError)
                .foregroundStyle(Design.Colors.error)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        } else if let comparison {
            if comparison.binary {
                Text("Binary file — interactive diff unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comparison.hunks.isEmpty {
                Text("No changes in this dimension")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(displayMode.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Use the hunk actions to update staging")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Design.Colors.surface)

                    SideBySideDiffView(
                        fileDiff: comparison,
                        hunkActions: comparisonHunkActions,
                        hunkActionsDisabled: mutationTask != nil,
                        onHunkAction: applyHunk
                    )
                }
            }
        } else {
            Text("No comparison is available for this file")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func applyHunk(_ action: DiffHunkAction, _ hunkIndex: Int) {
        guard let repo,
              let requestedStagingMode = self.displayMode.stagingMode,
              let comparison,
              hunkIndex >= 0,
              hunkIndex < comparison.hunks.count,
              (requestedStagingMode == .unstaged
               && (action == .stage || action == .rollback))
                  || (requestedStagingMode == .staged && action == .unstage),
              mutationTask == nil else { return }

        let expectedPath = path
        let selection = LineSelection(hunkIndex: UInt32(hunkIndex), oldLines: [], newLines: [])
        mutationTask = Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .stage:
                    try repo.stageLines(path: expectedPath, selections: [selection])
                case .unstage:
                    try repo.unstageLines(path: expectedPath, selections: [selection])
                case .rollback:
                    try repo.restoreUnstagedLines(path: expectedPath, selections: [selection])
                }
                await MainActor.run {
                    guard self.path == expectedPath else {
                        self.mutationTask = nil
                        return
                    }
                    self.mutationTask = nil
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    guard self.path == expectedPath else {
                        self.mutationTask = nil
                        return
                    }
                    self.mutationTask = nil
                    self.comparisonError = "\(error)"
                }
            }
        }
    }

    private func load() {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedMode = displayMode
        guard let repo else {
            isLoading = false
            return
        }
        task?.cancel()
        isLoading = true
        error = nil
        comparisonError = nil
        versions = nil
        comparison = nil
        task = Task.detached(priority: .userInitiated) {
            do {
                let value = try repo.stagingFileVersions(path: path)
                var comparison: FileDiff?
                var comparisonError: String?
                if let diffMode = requestedMode.diffMode {
                    do {
                        comparison = try repo.diffFileWithSettings(
                            path: path,
                            mode: diffMode,
                            settings: makeArborGitDiffSettings()
                        )
                    } catch {
                        comparisonError = "\(error)"
                    }
                }
                let loadedComparison = comparison
                let loadedComparisonError = comparisonError
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: self.path,
                        generation: generation,
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    versions = value
                    self.comparison = loadedComparison
                    self.comparisonError = loadedComparisonError
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: self.path,
                        generation: generation,
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.error = "\(error)"
                    isLoading = false
                }
            }
        }
    }
}

private struct ThreeVersionPane: View {
    let title: String
    let content: StagingVersionContent

    private var lines: [String] {
        content.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if content.truncated {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .help("Content truncated")
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))

            if !content.present {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle")
                    Text("Missing")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            } else if content.binary {
                Text("Binary file — diff preview unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(index + 1))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(line.isEmpty ? " " : line)
                                    .foregroundStyle(.primary)
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1)
        }
    }
}

/// Read-only view of the facts returned by `git check-attr` and Git's
/// effective line-ending conversion rules.
private struct FileAttributesInspector: View {
    let attributes: FileAttributes?
    let lineEndings: EffectiveLineEndings?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attributes")
                .font(.title3.weight(.semibold))
            Text("Resolved by Git for this file")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Design.Colors.error)
            } else if attributes == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let attributes {
                VStack(alignment: .leading, spacing: 5) {
                    attributeRow("Text", attributes.text)
                    attributeRow("EOL", attributes.eol)
                    attributeRow("Binary", attributes.binary)
                    attributeRow("Diff", attributes.diff)
                    attributeRow("Merge", attributes.merge)
                    attributeRow("Filter", attributes.filter)
                    attributeRow("Working-tree encoding", attributes.workingTreeEncoding)
                }
                Divider()
                Text("Effective line endings")
                    .font(.headline)
                if let lineEndings {
                    detailRow(
                        "Normalize on commit",
                        lineEndings.normalizeToLfOnCommit ? "LF" : "Keep original"
                    )
                    detailRow(
                        "Checkout",
                        lineEndings.checkoutLineEnding == .crlf ? "CRLF" : "LF"
                    )
                } else {
                    detailRow("Checkout", String(localized: "Unavailable"))
                }
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    @ViewBuilder
    private func attributeRow(_ name: LocalizedStringKey, _ value: AttributeValue) -> some View {
        detailRow(name, attributeValueText(value))
    }

    private func detailRow(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }

    private func attributeValueText(_ value: AttributeValue) -> String {
        switch value {
        case .set:
            return String(localized: "set")
        case .unset:
            return String(localized: "unset")
        case let .value(value):
            return value
        case .unspecified:
            return String(localized: "unspecified")
        }
    }
}
