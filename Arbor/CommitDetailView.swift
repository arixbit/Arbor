import SwiftUI
import AppKit

// MARK: - 提交详情（日志模式）

struct CommitDetailView: View {
    let repo: Repository?
    let commit: CommitInfo?
    let remotes: [RemoteInfo]
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onCreateBranch: (CommitInfo) -> Void
    /// Log context actions are owned by ContentView so conflict recovery can
    /// open the shared Merge Revisions workbench. Reflog keeps the local
    /// fallback implementation when these closures are omitted.
    var onRevertRequested: ((CommitInfo) -> Void)? = nil
    var onCherryPickRequested: ((CommitInfo) -> Void)? = nil
    /// These mirror rebased's Log action properties. The details panel and
    /// the changes/diff browser are independent: hiding commit metadata must
    /// not make the selected commit's changed files disappear.
    var showsMetadata: Bool = true
    /// Rebase's details pane is read-only and must not expose Log mutation actions.
    var showsActions: Bool = true
    var showsDiffPreview: Bool = true
    var diffPreviewVertical: Bool = false
    /// Log's MainFrame keeps commit metadata and the Changes browser in
    /// separate splitter components.  The metadata component reuses this
    /// view, but must not start a second hidden changes/diff loader.
    var showsChanges: Bool = true
    @State private var feedback: String?
    @State private var changedFiles: [TreeChange] = []
    @State private var selectedPath: String?
    @State private var fileDiff: FileDiff?
    @State private var diffError: String?
    @State private var filesError: String?
    @State private var presentationMode: DiffPresentationMode = .sideBySide
    @State private var signatureStatus: SignatureStatus?
    @State private var isLoadingChangedFiles = false
    @State private var detailsTask: Task<Void, Never>?
    @State private var diffTask: Task<Void, Never>?
    @State private var collapsedChangeFolders: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if let commit {
                if showsMetadata {
                    // MainFrame's right side is a details splitter: the
                    // commit metadata stays above the changes browser. The
                    // changes browser then has its own file-tree/diff-preview
                    // splitter. Keeping all regions in the workspace is
                    // essential; a sheet-based diff loses selected context.
                    VSplitView {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                commitHeader(commit)
                                if showsActions {
                                    inspectorActions(commit)
                                }
                            }
                            .padding(12)
                        }
                        .frame(minHeight: 220, idealHeight: 300, maxHeight: .infinity)

                        if showsChanges {
                            changedFilesView(commit: commit)
                                .frame(minHeight: 180, idealHeight: 390, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showsChanges {
                    changedFilesView(commit: commit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("选择一个提交查看详情").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if showsChanges { loadChangedFiles() }
        }
        .onDisappear {
            detailsTask?.cancel()
            diffTask?.cancel()
        }
        .onChange(of: commit?.id) { _, _ in
            feedback = nil
            selectedParent = 0
            collapsedChangeFolders = []
            if showsChanges { loadChangedFiles() }
        }
        .onChange(of: selectedParent) { _, _ in
            if showsChanges { loadChangedFiles() }
        }
        .onChange(of: selectedPath) { _, path in loadDiff(path) }
    }

    /// Rebased places commit actions after the metadata and immediately above
    /// the Changes browser. Keep the labels visible: these are primary actions
    /// in the Log workspace, not hidden overflow icons.
    private func inspectorActions(_ commit: CommitInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("还原此提交 (revert)") {
                    if let onRevertRequested {
                        onRevertRequested(commit)
                    } else {
                        revertCommit(commit)
                    }
                }
                    .disabled(commit.parentIds.count != 1 || repo == nil)
                Button("Cherry-pick") {
                    if let onCherryPickRequested {
                        onCherryPickRequested(commit)
                    } else {
                        cherryPick(commit)
                    }
                }
                    .disabled(repo == nil)
                Button("从此提交创建分支") { onCreateBranch(commit) }
                    .disabled(repo == nil)
                hostedCommitAction(commit)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func hostedCommitAction(_ commit: CommitInfo) -> some View {
        let candidates = hostedRemotes(for: commit)
        switch hostedRemoteActionPresentation(for: candidates.count) {
        case .direct where candidates.count == 1:
            let remote = candidates[0]
            Button("在浏览器中打开") { openInBrowser(commit, remote: remote) }
        case .submenu:
            Menu("在浏览器中打开") {
                ForEach(candidates, id: \.name) { remote in
                    Button(remote.name) {
                        openInBrowser(commit, remote: remote)
                    }
                }
            }
        case .direct, .hidden:
            EmptyView()
        }
    }

    private func hostedRemotes(for commit: CommitInfo) -> [RemoteInfo] {
        guard let repo else { return [] }
        return remotes.filter { remote in
            repo.permalink(remoteUrl: remote.url, commitId: commit.id) != nil
        }
    }

    @ViewBuilder
    private func commitHeader(_ commit: CommitInfo) -> some View {
        Text(commit.summary).font(.title2).bold()
        if !commit.messageBody.isEmpty {
            Text(commit.messageBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        infoRow("提交", commit.id)
        infoRow("作者", "\(commit.authorName) <\(commit.authorEmail)>")
        infoRow("提交者", "\(commit.committerName) <\(commit.committerEmail)>")
        infoRow("时间", dateStr(commit.time))
        if commit.hasSignature {
            infoRow("签名", signatureBadge)
        }
        infoRow("父提交", commit.parentIds.isEmpty ? "（无）" : commit.parentIds.joined(separator: "\n"))
        feedbackRow
        let refs = commit.refs + commit.tagRefs + commit.remoteRefs
        if !refs.isEmpty {
            infoRow("引用", refs.joined(separator: ", "))
        }
    }

    private func infoRow(_ label: String, _ value: some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            value
        }
        .font(.caption)
    }

    @ViewBuilder
    private var feedbackRow: some View {
        if let feedback {
            Text(feedback).foregroundStyle(feedback.hasPrefix("已还原") ? .green : .red)
        } else {
            EmptyView()
        }
    }

    private var signatureBadge: some View {
        Group {
            switch signatureStatus {
            case .valid:
                Label("已验证 (Good signature)", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            case .invalid:
                Label("签名无效 (BAD signature)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .unknown:
                Text("存在签名，验证器无法判定")
                    .foregroundStyle(.orange)
            default:
                Text("存在签名，验证中…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: commit?.id) {
            signatureStatus = nil
            guard let repo, let commit else { return }
            let status: SignatureStatus? = try? await Task.detached(priority: .userInitiated) {
                try repo.commitSignatureStatus(commitId: commit.id)
            }.value
            if let status {
                guard self.commit?.id == commit.id else { return }
                signatureStatus = status
            }
        }
    }

    @State private var selectedParent: Int = 0

    private var changeTree: [CommitChangeNode] {
        var roots: [CommitChangeNode] = []
        for change in changedFiles {
            let components = change.path.split(separator: "/")
            guard !components.isEmpty else { continue }
            let first = String(components[0])
            if let index = roots.firstIndex(where: { $0.name == first }) {
                roots[index].insert(components: Array(components.dropFirst()), change: change)
            } else {
                var node = CommitChangeNode(name: first, path: first)
                node.insert(components: Array(components.dropFirst()), change: change)
                roots.append(node)
            }
        }
        return roots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func changedFilesView(commit: CommitInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.headline)
                if isLoadingChangedFiles {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(changedFiles.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if commit.parentIds.count > 1 {
                    Picker("Parent", selection: $selectedParent) {
                        ForEach(Array(commit.parentIds.enumerated()), id: \.offset) { index, parentId in
                            Text("Parent \(index + 1) (\(String(parentId.prefix(7))))").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 200)
                } else if commit.parentIds.isEmpty {
                    Text("Root commit — 与空 tree 比较")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Diff View", selection: $presentationMode) {
                    ForEach(DiffPresentationMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 190)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Divider() }

            if let filesError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load changed files", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(filesError)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button("Retry") { loadChangedFiles() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if isLoadingChangedFiles && changedFiles.isEmpty {
                ProgressView("Loading changed files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No changed files")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if showsDiffPreview {
                    if diffPreviewVertical {
                        VSplitView {
                            changedFilesList
                            diffPreviewPanel
                                .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
                        }
                    } else {
                        HSplitView {
                            changedFilesList
                            diffPreviewPanel
                                .frame(minWidth: 220, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    changedFilesList
                }
            }
        }
    }

    /// Rebased's changes browser remains usable when the diff preview is
    /// toggled off. Keep the tree as a first-class view rather than replacing
    /// the whole inspector with an empty placeholder.
    private var changedFilesList: some View {
        List {
            ForEach(changeTree) { node in
                changeTreeNode(node)
            }
        }
        .listStyle(.inset)
        // Rebased keeps the commit-details inspector narrow. Its changes tree
        // is allowed to collapse to a compact path column so the diff preview
        // remains visible instead of forcing the whole inspector wider.
        .frame(minWidth: 104, idealWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var diffPreviewPanel: some View {
        Group {
            if let diffError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load diff", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(diffError)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    if let selectedPath {
                        Button("Retry") { loadDiff(selectedPath) }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if let fileDiff {
                if presentationMode == .unified {
                    UnifiedDiffView(fileDiff: fileDiff)
                } else {
                    SideBySideDiffView(fileDiff: fileDiff)
                }
            } else if selectedPath != nil {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a changed file to view its diff")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Design.Colors.canvas)
    }

    private func changeTreeNode(_ node: CommitChangeNode) -> AnyView {
        if let change = node.change, node.children.isEmpty {
            let row = HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(change.kind.displayTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Text(node.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(min(node.path.split(separator: "/").count - 1, 6)) * 10)
            .background(
                selectedPath == change.path
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
            .onTapGesture { selectedPath = change.path }
            .onTapGesture(count: 2) { selectedPath = change.path }
            .contextMenu {
                Button("查看差异") {
                    selectedPath = change.path
                }
            }
            return AnyView(row)
        }

        return AnyView(DisclosureGroup(isExpanded: Binding(
                get: { !collapsedChangeFolders.contains(node.path) },
                set: { expanded in
                    if expanded {
                        collapsedChangeFolders.remove(node.path)
                    } else {
                        collapsedChangeFolders.insert(node.path)
                    }
                }
            )) {
                ForEach(node.children) { child in
                    changeTreeNode(child)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(node.name)
                        .lineLimit(1)
                    Text("\(node.fileCount) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            })
    }

    private func loadChangedFiles() {
        detailsTask?.cancel()
        diffTask?.cancel()
        changedFiles = []
        selectedPath = nil
        fileDiff = nil
        diffError = nil
        filesError = nil
        isLoadingChangedFiles = false
        guard let repo, let commit else { return }
        let commitID = commit.id
        let parentIndex = commit.parentIds.isEmpty ? nil : UInt32(selectedParent)
        isLoadingChangedFiles = true
        let task = Task.detached(priority: .userInitiated) {
            do {
                // HISTORY-001:root 与空 tree 比较;merge 按 selectedParent 选择父
                let diff = try repo.commitDiff(commitId: commitID, parentIndex: parentIndex)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.commit?.id == commitID,
                          self.selectedParent == Int(parentIndex ?? 0) else { return }
                    self.isLoadingChangedFiles = false
                    self.changedFiles = diff.changes
                }
            } catch {
                await MainActor.run {
                    guard self.commit?.id == commitID,
                          self.selectedParent == Int(parentIndex ?? 0) else { return }
                    self.isLoadingChangedFiles = false
                    self.filesError = "\(error)"
                }
            }
        }
        detailsTask = task
    }

    private func loadDiff(_ path: String?) {
        diffTask?.cancel()
        fileDiff = nil
        diffError = nil
        guard let repo, let commit, let path else { return }
        let commitID = commit.id
        let parentIndex = commit.parentIds.isEmpty ? nil : selectedParent
        let task = Task.detached(priority: .userInitiated) {
            do {
                // The engine handles both normal/merge commits and root
                // commits (root is compared with the empty tree).
                let diff = try repo.commitFileDiffWithSettings(
                    commitId: commitID,
                    parentIndex: parentIndex.map(UInt32.init),
                    path: path,
                    settings: makeArborGitDiffSettings()
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.commit?.id == commitID,
                          self.selectedPath == path,
                          self.selectedParent == parentIndex else { return }
                    self.fileDiff = diff
                    self.diffError = nil
                }
            } catch {
                await MainActor.run {
                    guard self.commit?.id == commitID,
                          self.selectedPath == path,
                          self.selectedParent == parentIndex else { return }
                    self.diffError = "\(error)"
                    self.fileDiff = nil
                }
            }
        }
        diffTask = task
    }

    private func revertCommit(_ commit: CommitInfo) {
        guard let repo else { return }
        let id = commit.id
        Task.detached(priority: .userInitiated) {
            do {
                let newId = try repo.revert(commitId: id)
                await MainActor.run {
                    guard self.commit?.id == id else { return }
                    self.feedback = "已还原：\(String(newId.prefix(7)))"
                    self.onReverted()
                }
            } catch {
                await MainActor.run { self.feedback = "\(error)" }
            }
        }
    }

    private func cherryPick(_ commit: CommitInfo) {
        guard let repo else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let newId = try repo.cherryPick(commitId: commit.id)
                await MainActor.run {
                    guard self.commit?.id == commit.id else { return }
                    self.feedback = "已 Cherry-pick：\(String(newId.prefix(7)))"
                    self.onCherryPicked()
                }
            } catch {
                await MainActor.run { self.feedback = "\(error)" }
            }
        }
    }

    /// 在用户选择的 hosted remote 打开提交 permalink。
    private func openInBrowser(_ commit: CommitInfo, remote: RemoteInfo) {
        guard let repo else { return }
        let url = remote.url
        let id = commit.id
        Task.detached(priority: .userInitiated) {
            let link = repo.permalink(remoteUrl: url, commitId: id)
            await MainActor.run {
                guard let link else {
                    self.feedback = "该远程不支持 permalink"
                    return
                }
                if let nsUrl = URL(string: link) {
                    NSWorkspace.shared.open(nsUrl)
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }
}

/// A small value-tree for the commit inspector. Rebased's changes browser
/// groups paths into expandable folders; showing a flat slash-delimited list
/// loses that interaction and makes a large commit impossible to scan.
private struct CommitChangeNode: Identifiable {
    let name: String
    let path: String
    var change: TreeChange?
    var children: [CommitChangeNode] = []

    var id: String { path }

    var fileCount: Int {
        if children.isEmpty {
            return change == nil ? 0 : 1
        }
        return children.reduce(0) { $0 + $1.fileCount }
    }

    mutating func insert(components: [Substring], change: TreeChange) {
        guard let first = components.first else {
            self.change = change
            return
        }

        let childName = String(first)
        let childPath = "\(path)/\(childName)"
        if let index = children.firstIndex(where: { $0.name == childName }) {
            children[index].insert(components: Array(components.dropFirst()), change: change)
        } else {
            var child = CommitChangeNode(name: childName, path: childPath)
            child.insert(components: Array(components.dropFirst()), change: change)
            children.append(child)
            children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
