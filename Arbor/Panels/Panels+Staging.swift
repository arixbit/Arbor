import SwiftUI
import AppKit
import UniformTypeIdentifiers


enum GitStageViewSettings {
    static let keyPrefix = "arbor.git.stage.ui.project.v1:"
    static let ignoredFilesShownKey = "ignoredFilesShown"

    static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return "\(keyPrefix)\(data.base64EncodedString()):\(ignoredFilesShownKey)"
    }

    static func ignoredFilesShown(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(for: projectPath) else { return false }
        return defaults.bool(forKey: key)
    }

    static func saveIgnoredFilesShown(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        defaults.set(value, forKey: key)
    }
}

enum StagingPreviewMode: String, CaseIterable {
    case unstaged
    case staged

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        }
    }
}

enum StagingVersionAction: String, CaseIterable, Equatable {
    case local
    case staged
}

enum StagingPreviewFileAction: String, CaseIterable, Equatable {
    case stage
    case unstage
    case revertUnstaged
}

func stagingPreviewDiffMode(for mode: StagingPreviewMode) -> DiffMode {
    switch mode {
    case .unstaged: .worktreeToIndex
    case .staged: .indexToHead
    }
}

struct StagingVersionPresence: Equatable {
    let head: Bool
    let staged: Bool
    let local: Bool
}

func stagingVersionPresence(for entry: StagingEntry) -> StagingVersionPresence {
    StagingVersionPresence(
        head: entry.headPresent,
        staged: entry.stagedPresent,
        local: entry.localPresent
    )
}

/// Keep file-level staging preview actions derived from the same two-sided
/// status model as the Changes Browser. In particular, an untracked file can
/// be staged but cannot be reverted to an index version that does not exist.
func stagingPreviewFileActions(
    for entry: FileEntry?,
    mode: StagingPreviewMode
) -> [StagingPreviewFileAction] {
    guard let entry else { return [] }
    switch mode {
    case .unstaged:
        guard entry.unstaged != .unchanged,
              entry.unstaged != .ignored,
              entry.unstaged != .conflicted else { return [] }
        var actions: [StagingPreviewFileAction] = [.stage]
        if entry.unstaged != .untracked {
            actions.append(.revertUnstaged)
        }
        return actions
    case .staged:
        guard entry.staged != .unchanged,
              entry.staged != .ignored,
              entry.staged != .conflicted else { return [] }
        return [.unstage]
    }
}

/// Hunk-level actions exposed by the staging diff preview. Keep this matrix
/// pure so status edge cases are testable without constructing SwiftUI views.
func stagingHunkActions(
    for entry: FileEntry?,
    mode: StagingPreviewMode,
    diff: FileDiff?
) -> [DiffHunkAction] {
    guard let diff, !diff.binary, !diff.hunks.isEmpty else { return [] }
    let fileActions = stagingPreviewFileActions(for: entry, mode: mode)
    switch mode {
    case .unstaged:
        var actions: [DiffHunkAction] = []
        if fileActions.contains(.stage) { actions.append(.stage) }
        if fileActions.contains(.revertUnstaged) { actions.append(.rollback) }
        return actions
    case .staged:
        return fileActions.contains(.unstage) ? [.unstage] : []
    }
}

func resolvedStagingPreviewMode(
    preferred: StagingPreviewMode,
    available: [StagingPreviewMode]
) -> StagingPreviewMode? {
    guard !available.isEmpty else { return nil }
    return available.contains(preferred) ? preferred : available[0]
}

func stagingVersionActions(
    for entry: FileEntry,
    presence: StagingVersionPresence? = nil
) -> [StagingVersionAction] {
    var actions: [StagingVersionAction] = []
    let hasLocal = presence?.local ?? (
        entry.unstaged != .deleted
            && entry.unstaged != .ignored
            && entry.unstaged != .conflicted
            && !(entry.staged == .deleted && entry.unstaged == .unchanged)
    )
    let hasStaged = presence?.staged ?? (
        entry.staged != .unchanged
            && entry.staged != .deleted
            && entry.staged != .ignored
            && entry.staged != .conflicted
    )
    if hasLocal { actions.append(.local) }
    if hasStaged { actions.append(.staged) }
    return actions
}

struct RebasedChangeListHeader: View {
    let list: ChangeListInfo
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    let onActivate: (String) -> Void
    let onMovePaths: ([String], String) -> Void
    let onDropShelfIntoChangeList: (String, [String]?, String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: list.isActive ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(list.isActive ? Color.accentColor : Color.secondary)
            Image(systemName: "list.bullet.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(list.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(list.paths.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Menu {
                Button(list.isActive ? "Active Changelist" : "Set Active") {
                    onActivate(list.name)
                }
                .disabled(list.isActive)
                Divider()
                Button("Rename…") { onRename(list.name) }
                Button("Delete", role: .destructive) { onDelete(list.name) }
                    .disabled(list.isDefault)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 1)
        .dropDestination(for: String.self) { paths, _ in
            if let shelfPayload = paths.compactMap(parseShelfDropPayload).first {
                switch shelfPayload {
                case let .shelf(name):
                    onDropShelfIntoChangeList(name, nil, list.name)
                case let .member(shelf, path):
                    onDropShelfIntoChangeList(shelf, [path], list.name)
                }
                return true
            }
            let payloads = paths.filter { !$0.hasPrefix("arbor-shelf") }
            guard !payloads.isEmpty else { return false }
            onMovePaths(payloads, list.name)
            return true
        }
    }
}

/// Commit/Stash 工作区内的轻量 diff 预览。
///
/// rebased 的 Stage panel 会在变更树旁/下方保留 diff preview，不会把右侧
/// Git Log 编辑器替换掉。这里直接复用引擎已经提供的三层 staging diff，
/// 因而 staged + unstaged 同时存在时仍然可以切换查看两个真实维度。
struct StagingDiffPreviewView: View {
    let repo: Repository?
    let path: String?
    let entry: FileEntry?
    let refreshToken: Int
    @Binding var selectionModePath: String?
    @Binding var previewMode: StagingPreviewMode
    @Binding var showThreeVersions: Bool
    let onStage: (String) -> Void
    let onUnstage: (String) -> Void
    let onRevertUnstaged: (String) -> Void
    let onChanged: () -> Void
    let onClose: () -> Void

    @State var result: StagingFileDiff?
    @State var isLoading = false
    @State var error: String?
    @State var task: Task<Void, Never>?
    @State var hunkTask: Task<Void, Never>?
    @State var loadGeneration = 0

    var availableModes: [StagingPreviewMode] {
        var modes: [StagingPreviewMode] = []
        if result?.unstaged != nil { modes.append(.unstaged) }
        if result?.staged != nil { modes.append(.staged) }
        return modes
    }

    var activeDiff: FileDiff? {
        switch previewMode {
        case .unstaged: result?.unstaged
        case .staged: result?.staged
        }
    }

    var fileActions: [StagingPreviewFileAction] {
        stagingPreviewFileActions(for: entry, mode: previewMode)
    }

    var canSelectLines: Bool {
        guard let activeDiff, !activeDiff.binary, !activeDiff.hunks.isEmpty else { return false }
        return fileActions.contains(previewMode == .unstaged ? .stage : .unstage)
    }

    var hunkActions: [DiffHunkAction] {
        stagingHunkActions(for: entry, mode: previewMode, diff: activeDiff)
    }

    var body: some View {
        if showThreeVersions, let path {
            ThreeVersionComparisonView(
                repo: repo,
                path: path,
                entry: entry,
                refreshToken: refreshToken,
                onChanged: onChanged,
                onClose: { showThreeVersions = false }
            )
        } else if selectionModePath == path, let path {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Stage line by line · \(path)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        selectionModePath = nil
                    } label: {
                        Label("Back to preview", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Return to the file diff preview")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide changes preview")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Design.Colors.surface)

                DiffDetailView(
                    repo: repo,
                    entry: entry,
                    onChanged: onChanged,
                    selectionModePath: selectionModePath,
                    initialMode: stagingPreviewDiffMode(for: previewMode),
                    refreshToken: refreshToken
                )
            }
        } else {
            ordinaryPreview
        }
    }

    var ordinaryPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text(path.map { "Preview · \($0)" } ?? "Changes preview")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if availableModes.count > 1 {
                    Picker("Diff", selection: $previewMode) {
                        ForEach(availableModes, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 150)
                    .disabled(hunkTask != nil)
                }
                if canSelectLines, let path {
                    Button {
                        selectionModePath = path
                    } label: {
                        Label("Select Lines", systemImage: "selection.pin.in.out")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hunkTask != nil)
                    .help("Select lines to stage or unstage")
                }
                if previewMode == .unstaged {
                    if fileActions.contains(.stage), let path {
                        Button {
                            onStage(path)
                        } label: {
                            Label("Stage", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hunkTask != nil)
                        .help("Stage this file")
                    }
                    if fileActions.contains(.revertUnstaged), let path {
                        Button(role: .destructive) {
                            onRevertUnstaged(path)
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hunkTask != nil)
                        .help("Revert unstaged changes to the staged version")
                    }
                } else if fileActions.contains(.unstage), let path {
                    Button {
                        onUnstage(path)
                    } label: {
                        Label("Unstage", systemImage: "minus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hunkTask != nil)
                    .help("Unstage this file")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide changes preview")
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
                        .padding(10)
                } else if isLoading {
                    ProgressView("Loading diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let activeDiff {
                    if activeDiff.binary {
                        Text("Binary file — diff preview unavailable")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if activeDiff.hunks.isEmpty {
                        Text("No changes in this dimension")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SideBySideDiffView(
                            fileDiff: activeDiff,
                            hunkActions: hunkActions,
                            hunkActionsDisabled: hunkTask != nil,
                            onHunkAction: applyHunk
                        )
                    }
                } else if path == nil {
                    Text("Select a changed file to preview its diff")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Design.Colors.canvas)
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: entry) { _, _ in load() }
        .onChange(of: refreshToken) { _, _ in load() }
        .onDisappear {
            loadGeneration &+= 1
            task?.cancel()
            hunkTask?.cancel()
        }
        .onChange(of: availableModes) { _, modes in
            if let resolved = resolvedStagingPreviewMode(preferred: previewMode, available: modes),
               resolved != previewMode {
                previewMode = resolved
            }
        }
    }

    func applyHunk(_ action: DiffHunkAction, _ hunkIndex: Int) {
        guard let repo, let path, let activeDiff,
              hunkIndex >= 0, hunkIndex < activeDiff.hunks.count,
              hunkTask == nil else { return }
                        let selection = LineSelection(hunkIndex: UInt32(hunkIndex), oldLines: [], newLines: [])
        let expectedPath = path
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
                    guard self.path == expectedPath else {
                        self.hunkTask = nil
                        return
                    }
                    self.hunkTask = nil
                    self.onChanged()
                    self.load()
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    guard self.path == expectedPath else {
                        self.hunkTask = nil
                        return
                    }
                    self.hunkTask = nil
                    self.error = "\(error)"
                }
            }
        }
    }

    func load() {
        loadGeneration &+= 1
        let generation = loadGeneration
        task?.cancel()
        result = nil
        error = nil
        isLoading = false
        guard let repo, let path else { return }
        let expectedPath = path
        isLoading = true
        task = Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.stagingDiff(path: expectedPath, ignoreWhitespace: false)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: expectedPath,
                        generation: generation,
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.result = diff
                    self.isLoading = false
                    self.error = nil
                    let modes: [StagingPreviewMode] = [
                        diff.unstaged != nil ? .unstaged : nil,
                        diff.staged != nil ? .staged : nil
                    ].compactMap { $0 }
                    if let resolved = resolvedStagingPreviewMode(
                        preferred: self.previewMode,
                        available: modes
                    ) {
                        self.previewMode = resolved
                    }
                }
            } catch {
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: expectedPath,
                        generation: generation,
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.result = nil
                    self.isLoading = false
                    self.error = "\(error)"
                }
            }
        }
    }
}
