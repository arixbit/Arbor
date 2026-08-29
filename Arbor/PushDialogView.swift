import SwiftUI

enum PushDialogMode: Equatable {
    case push
    case commitAndPush
    case pushUpToCommit
    case addCommitsToRemoteBranch

    var title: String {
        switch self {
        case .push: "Push"
        case .commitAndPush: "Commit and Push"
        case .pushUpToCommit: "Push Up to Commit"
        case .addCommitsToRemoteBranch: "Add Commits to Remote Branch"
        }
    }

    var actionTitle: String {
        switch self {
        case .push: "Push"
        case .commitAndPush: "Commit and Push"
        case .pushUpToCommit: "Push"
        case .addCommitsToRemoteBranch: "Push"
        }
    }

    var allowsCommitOnlyFallbackWithoutRemote: Bool {
        self == .commitAndPush
    }
}

enum PushDialogRefspec {
    static func normalizeTargetBranch(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = value.hasPrefix("refs/heads/")
            ? String(value.dropFirst("refs/heads/".count))
            : value
        return GitBranchNameCleanup.cleanUp(branch)
    }

    static func pushUpToCommit(sourceRevision: String, targetBranch: String) -> String? {
        let source = sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = normalizeTargetBranch(targetBranch)
        guard !source.isEmpty, !target.isEmpty else { return nil }
        return "\(source):refs/heads/\(target)"
    }
}

enum PushDialogTagMode: String, CaseIterable, Identifiable {
    case all
    case currentBranch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All tags"
        case .currentBranch: "Tags reachable from current branch"
        }
    }
}

/// Rebased 风格 Push 选择器：远程、目标分支、force 和将被纳入操作的提交预览。
struct PushDialogView: View {
    let remotes: [RemoteInfo]
    let branches: [BranchInfo]
    let commits: [CommitInfo]
    let mode: PushDialogMode
    let defaultRemote: String?
    let defaultBranch: String?
    let defaultSourceRevision: String?
    let currentHasUpstream: Bool
    let protectedBranchPatterns: [String]
    let onCancel: () -> Void
    let onPush: (String?, String?, Bool, Bool, Bool, String?, PushDialogTagMode?, Bool) -> Void
    var onConfigureRemotes: () -> Void = {}
    var onConfigureSSH: () -> Void = {}
    var showsConfigurationActions = true
    var showsSSHConfigurationAction = true

    @State private var remote: String
    @State private var branch: String
    @State private var sourceRevision: String
    @State private var force = false
    @State private var forceWithLease: Bool

    init(
        remotes: [RemoteInfo],
        branches: [BranchInfo],
        commits: [CommitInfo],
        mode: PushDialogMode = .commitAndPush,
        defaultRemote: String?,
        defaultBranch: String?,
        defaultSourceRevision: String? = nil,
        currentHasUpstream: Bool = true,
        protectedBranchPatterns: [String] = [],
        defaultRefspec: String? = nil,
        defaultPushTagMode: PushDialogTagMode? = nil,
        defaultRunHooks: Bool = true,
        onCancel: @escaping () -> Void,
        onPush: @escaping (String?, String?, Bool, Bool, Bool, String?, PushDialogTagMode?, Bool) -> Void,
        onConfigureRemotes: @escaping () -> Void = {},
        onConfigureSSH: @escaping () -> Void = {},
        showsConfigurationActions: Bool = true,
        showsSSHConfigurationAction: Bool = true
    ) {
        self.remotes = remotes
        self.branches = branches
        self.commits = commits
        self.mode = mode
        self.defaultRemote = defaultRemote
        self.defaultBranch = defaultBranch
        self.defaultSourceRevision = defaultSourceRevision
        self.currentHasUpstream = currentHasUpstream
        self.protectedBranchPatterns = protectedBranchPatterns
        self.onCancel = onCancel
        self.onPush = onPush
        self.onConfigureRemotes = onConfigureRemotes
        self.onConfigureSSH = onConfigureSSH
        self.showsConfigurationActions = showsConfigurationActions
        self.showsSSHConfigurationAction = showsSSHConfigurationAction
        _remote = State(
            initialValue: resolveSelectedRemoteName(
                selectedRemote: defaultRemote,
                availableRemoteNames: remotes.map(\.name)
            ) ?? ""
        )
        _branch = State(initialValue: defaultBranch ?? branches.first(where: { $0.isCurrent })?.name ?? "")
        _sourceRevision = State(initialValue: defaultSourceRevision ?? "")
        _forceWithLease = State(initialValue: GitPushSettings.forceWithLeaseDefault())
        _publishBranch = State(initialValue: !currentHasUpstream)
        _useCustomRefspec = State(initialValue: defaultRefspec != nil)
        _customRefspec = State(initialValue: defaultRefspec ?? "")
        _pushTags = State(initialValue: defaultPushTagMode != nil)
        _pushTagMode = State(initialValue: defaultPushTagMode ?? .all)
        _runHooks = State(initialValue: defaultRunHooks)
    }

    @State private var publishBranch: Bool
    @State private var useCustomRefspec = false
    @State private var customRefspec = ""
    @State private var pushTags: Bool
    @State private var pushTagMode: PushDialogTagMode
    @State private var runHooks: Bool

    private var selectedBranchIsProtected: Bool {
        GitProtectedBranchRules.matches(normalizedTargetBranch, patterns: protectedBranchPatterns)
    }

    private var normalizedTargetBranch: String {
        PushDialogRefspec.normalizeTargetBranch(branch)
    }

    private var generatedPushUpRefspec: String? {
        PushDialogRefspec.pushUpToCommit(
            sourceRevision: sourceRevision,
            targetBranch: branch
        )
    }

    private var selectedRefspec: String? {
        if useCustomRefspec {
            let value = customRefspec.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if mode == .pushUpToCommit || mode == .addCommitsToRemoteBranch {
            return generatedPushUpRefspec
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title).font(.title3).bold()
            if remotes.isEmpty {
                Text(mode.allowsCommitOnlyFallbackWithoutRemote
                    ? "当前仓库没有配置远程；确认后只提交，不推送。"
                    : "当前仓库没有配置远程；请先配置 remote。")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("远程", selection: $remote) {
                        ForEach(remotes, id: \.name) { item in
                            Text("\(item.name) · \(item.url)").tag(item.name)
                        }
                    }
                    if showsConfigurationActions {
                        HStack(spacing: 8) {
                            Button("Configure Remotes…") { onConfigureRemotes() }
                            if showsSSHConfigurationAction {
                                Button("SSH Settings…") { onConfigureSSH() }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if remotes.count > 1 && !remotes.contains(where: { $0.name == remote }) {
                    Text("请选择 remote 后再推送。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if mode == .pushUpToCommit || mode == .addCommitsToRemoteBranch {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source revision")
                            .font(.subheadline.weight(.medium))
                        TextField("commit hash or revision", text: $sourceRevision)
                            .textFieldStyle(.roundedBorder)
                        Text("The source can be a detached commit; choose the remote target branch below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Target branch")
                            .font(.subheadline.weight(.medium))
                        TextField("refs/heads/branch", text: $branch)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    Picker("分支", selection: $branch) {
                        ForEach(branches, id: \.name) { item in
                            Text(item.name).tag(item.name)
                        }
                    }
                }
                Toggle("force push", isOn: $force)
                    .disabled(selectedBranchIsProtected)
                if selectedBranchIsProtected {
                    Label("Force push is disabled for this protected branch.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if force {
                    Toggle("Use force-with-lease (safer)", isOn: $forceWithLease)
                    Text(forceWithLease
                        ? "仅当远程仍指向你最近看到的提交时才覆盖。"
                        : "直接覆盖远程分支，可能丢失其他人的提交。")
                        .font(.caption)
                        .foregroundStyle(forceWithLease ? Color.secondary : Color.orange)
                }
                if mode == .push {
                    Toggle("Publish branch / set upstream", isOn: $publishBranch)
                    Toggle("Push tags", isOn: $pushTags)
                    if pushTags {
                        Picker("Tag mode", selection: $pushTagMode) {
                            ForEach(PushDialogTagMode.allCases) { tagMode in
                                Text(tagMode.title).tag(tagMode)
                            }
                        }
                    }
                    Toggle("Run git hooks", isOn: $runHooks)
                }
                if mode != .commitAndPush {
                    Toggle("Use custom refspec", isOn: $useCustomRefspec)
                    if useCustomRefspec {
                        TextField("e.g. HEAD:refs/heads/release", text: $customRefspec)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Divider()
                HStack {
                    Text("Commits")
                        .font(.headline)
                    Spacer()
                    Text("\(commits.count) loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if commits.isEmpty {
                    Text("No local commits loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(commits.prefix(12), id: \.id) { commit in
                                HStack(spacing: 7) {
                                    Image(systemName: commit.isHead ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(commit.isHead ? .blue : .secondary)
                                    Text(commit.shortId)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(commit.summary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 150)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                if remotes.isEmpty && !mode.allowsCommitOnlyFallbackWithoutRemote {
                    if showsConfigurationActions {
                        Button("Configure Remotes…") { onConfigureRemotes() }
                    }
                } else {
                    Button(remotes.isEmpty ? "提交" : mode.actionTitle) {
                        onPush(
                            remotes.isEmpty ? nil : remote,
                            normalizedTargetBranch.isEmpty ? nil : normalizedTargetBranch,
                            force && !selectedBranchIsProtected,
                            publishBranch,
                            force && forceWithLease,
                            selectedRefspec,
                            mode == .push && pushTags ? pushTagMode : nil,
                            mode == .push && !runHooks
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        (!remotes.isEmpty && !remotes.contains(where: { $0.name == remote }))
                            || ((mode == .pushUpToCommit || mode == .addCommitsToRemoteBranch)
                                && selectedRefspec == nil)
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: branch) { _, value in
            let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
            if cleaned != value { branch = cleaned }
            if selectedBranchIsProtected { force = false }
        }
    }
}

/// The project-level Push All action has no single remote/branch selector, but
/// IntelliJ still presents the two push-wide options before dispatching roots.
struct MultiRootPushOptionsDialog: View {
    let onCancel: () -> Void
    let onPush: (PushDialogTagMode?, Bool, Bool, Bool) -> Void

    @State private var pushTags = false
    @State private var pushTagMode: PushDialogTagMode = .all
    @State private var runHooks = true
    @State private var force = false
    @State private var forceWithLease = GitPushSettings.forceWithLeaseDefault()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Push All Git Roots")
                .font(.title3)
                .bold()
            Text("The selected options apply to every root included in this operation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Push tags", isOn: $pushTags)
            if pushTags {
                Picker("Tag mode", selection: $pushTagMode) {
                    ForEach(PushDialogTagMode.allCases) { tagMode in
                        Text(tagMode.title).tag(tagMode)
                    }
                }
            }
            Toggle("Run git hooks", isOn: $runHooks)
            Toggle("Force push", isOn: $force)
            if force {
                Toggle("Use force-with-lease (safer)", isOn: $forceWithLease)
                Text(forceWithLease
                    ? "Each root is overwritten only while its remote-tracking tip is unchanged."
                    : "This can overwrite remote commits in every selected root."
                )
                .font(.caption)
                .foregroundStyle(forceWithLease ? Color.secondary : Color.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Push All") {
                    onPush(
                        pushTags ? pushTagMode : nil,
                        !runHooks,
                        force,
                        force && forceWithLease
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
