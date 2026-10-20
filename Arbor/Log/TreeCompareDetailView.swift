import SwiftUI
import AppKit


/// Reverse a parsed diff for IntelliJ's default branch comparison direction:
/// the current working tree is the left/base side and the selected branch is
/// the right side. The engine intentionally returns revision → worktree, so
/// this presentation-only transform keeps the engine API unambiguous.
func reversedFileDiffForPresentation(_ diff: FileDiff) -> FileDiff {
    let hunks = diff.hunks.map { hunk in
        DiffHunk(
            oldStart: hunk.newStart,
            newStart: hunk.oldStart,
            oldLines: hunk.newLines.map { line in
                switch line.kind {
                case .context:
                    DiffLine(
                        kind: .context,
                        oldLine: line.newLine,
                        newLine: line.oldLine,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                case .addition, .deletion:
                    DiffLine(
                        kind: .deletion,
                        oldLine: line.newLine,
                        newLine: 0,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                }
            },
            newLines: hunk.oldLines.map { line in
                switch line.kind {
                case .context:
                    DiffLine(
                        kind: .context,
                        oldLine: line.newLine,
                        newLine: line.oldLine,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                case .addition, .deletion:
                    DiffLine(
                        kind: .addition,
                        oldLine: 0,
                        newLine: line.oldLine,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                }
            }
        )
    }
    return FileDiff(path: diff.path, binary: diff.binary, hunks: hunks)
}

/// v0.4 两个 revision 的文件变化详情，复用现有 side-by-side diff。
struct TreeCompareDetailView: View {
    let repo: Repository?
    let change: TreeChange?
    let selectedChanges: [TreeChange]
    let selectedPaths: Set<String>
    let rev1: String
    let rev2: String
    let comparesWithWorkingTree: Bool
    let projectPath: String?
    let onSelectPath: (String) -> Void
    @State private var fileDiff: FileDiff?
    @State private var error: String?
    @State private var diffTask: Task<Void, Never>?
    @State private var swapSides: Bool

    init(
        repo: Repository?,
        change: TreeChange?,
        selectedChanges: [TreeChange],
        selectedPaths: Set<String>,
        rev1: String,
        rev2: String,
        comparesWithWorkingTree: Bool,
        projectPath: String? = nil,
        onSelectPath: @escaping (String) -> Void
    ) {
        self.repo = repo
        self.change = change
        self.selectedChanges = selectedChanges
        self.selectedPaths = selectedPaths
        self.rev1 = rev1
        self.rev2 = rev2
        self.comparesWithWorkingTree = comparesWithWorkingTree
        self.projectPath = projectPath
        self.onSelectPath = onSelectPath
        _swapSides = State(
            initialValue: GitCompareBranchesSettings.swapSides(for: projectPath)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path).font(.headline)
                        Text(comparesWithWorkingTree
                             ? (swapSides
                                ? "\(rev1) → Working Tree"
                                : "Working Tree → \(rev1)")
                             : "\(rev1) → \(rev2)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if comparesWithWorkingTree {
                        Button {
                            swapSides.toggle()
                            GitCompareBranchesSettings.saveSwapSides(
                                swapSides,
                                for: projectPath
                            )
                            load()
                        } label: {
                            Label("Swap Sides", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .help(swapSides
                              ? "Show the working tree on the left"
                              : "Show the selected branch on the left")
                    }
                    if selectedPaths.count > 1 {
                        Text("\(selectedPaths.count) selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            selectAdjacentChange(offset: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Previous File")
                        .disabled(!canSelectAdjacentChange(offset: -1))
                        Button {
                            selectAdjacentChange(offset: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Next File")
                        .disabled(!canSelectAdjacentChange(offset: 1))
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let fileDiff {
                    SideBySideDiffView(fileDiff: fileDiff)
                } else {
                    ProgressView()
                }
            } else {
                Text("选择一个文件查看比较结果").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: change?.path) { _, _ in load() }
        .onChange(of: rev1) { _, _ in load() }
        .onChange(of: rev2) { _, _ in load() }
        .onChange(of: comparesWithWorkingTree) { _, _ in load() }
        .onChange(of: swapSides) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            guard comparesWithWorkingTree else { return }
            let persisted = GitCompareBranchesSettings.swapSides(for: projectPath)
            if persisted != swapSides {
                swapSides = persisted
            }
        }
        .onAppear {
            swapSides = GitCompareBranchesSettings.swapSides(for: projectPath)
            load()
        }
        .onDisappear { diffTask?.cancel() }
    }

    private func canSelectAdjacentChange(offset: Int) -> Bool {
        guard let index = selectedChanges.firstIndex(where: { $0.path == change?.path }) else {
            return false
        }
        return selectedChanges.indices.contains(index + offset)
    }

    private func selectAdjacentChange(offset: Int) {
        guard let index = selectedChanges.firstIndex(where: { $0.path == change?.path }),
              selectedChanges.indices.contains(index + offset) else { return }
        onSelectPath(selectedChanges[index + offset].path)
    }

    private func load() {
        diffTask?.cancel()
        fileDiff = nil
        error = nil
        guard let repo, let change else {
            return
        }
        let path = change.path
        let expectedRev1 = rev1
        let expectedRev2 = rev2
        let expectedWorkingTreeMode = comparesWithWorkingTree
        let expectedSwapSides = swapSides
        let task = Task.detached(priority: .userInitiated) {
            do {
                let rawDiff: FileDiff
                if expectedWorkingTreeMode {
                    rawDiff = try repo.diffRevisionPathWithWorktreeWithSettings(
                        revision: expectedRev1,
                        revisionPath: change.oldPath ?? path,
                        worktreePath: path,
                        settings: makeArborGitDiffSettings()
                    )
                } else {
                    rawDiff = try repo.diffCommitsWithSettings(
                        rev1: expectedRev1,
                        rev2: expectedRev2,
                        path: path,
                        settings: makeArborGitDiffSettings()
                    )
                }
                let diff = expectedWorkingTreeMode && !expectedSwapSides
                    ? reversedFileDiffForPresentation(rawDiff)
                    : rawDiff
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.rev1 == expectedRev1,
                          self.rev2 == expectedRev2,
                          self.comparesWithWorkingTree == expectedWorkingTreeMode,
                          self.swapSides == expectedSwapSides,
                          self.change?.path == path else { return }
                    self.fileDiff = diff
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.rev1 == expectedRev1,
                          self.rev2 == expectedRev2,
                          self.comparesWithWorkingTree == expectedWorkingTreeMode,
                          self.swapSides == expectedSwapSides,
                          self.change?.path == path else { return }
                    self.error = "\(error)"
                    self.fileDiff = nil
                }
            }
        }
        diffTask = task
    }
}
