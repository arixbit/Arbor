import SwiftUI

/// The option set exposed by IntelliJ's GitPullDialog. REBASE is kept as an
/// option even though the VCS menu seeds it from its Merge/Rebase entry.
enum GitPullDialogOption: String, CaseIterable, Codable, Hashable, Identifiable {
    case rebase
    case ffOnly
    case noFF
    case squash
    case noCommit
    case noVerify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rebase: "Rebase"
        case .ffOnly: "Fast-forward only"
        case .noFF: "No fast-forward"
        case .squash: "Squash commit"
        case .noCommit: "Do not commit"
        case .noVerify: "Do not run Git hooks"
        }
    }

    var flag: String {
        switch self {
        case .rebase: "--rebase"
        case .ffOnly: "--ff-only"
        case .noFF: "--no-ff"
        case .squash: "--squash"
        case .noCommit: "--no-commit"
        case .noVerify: "--no-verify"
        }
    }

    func isSuitable(with selected: Set<GitPullDialogOption>) -> Bool {
        let other = selected.subtracting([self])
        switch self {
        case .rebase:
            return other.isDisjoint(with: [.ffOnly, .noFF, .squash, .noCommit])
        case .ffOnly:
            return other.isDisjoint(with: [.noFF, .squash, .rebase])
        case .noFF:
            return other.isDisjoint(with: [.ffOnly, .squash, .rebase])
        case .squash:
            return other.isDisjoint(with: [.noFF, .ffOnly, .rebase])
        case .noCommit:
            return !other.contains(.rebase)
        case .noVerify:
            return true
        }
    }
}

/// Keep the default remote deterministic and safe when a branch has no valid
/// tracking remote. IntelliJ prefers the tracked remote, then its default
/// remote, and finally the first configured remote.
func defaultPullRemoteName(
    preferredRemote: String?,
    availableRemoteNames: [String]
) -> String? {
    guard !availableRemoteNames.isEmpty else { return nil }
    if let preferredRemote, availableRemoteNames.contains(preferredRemote) {
        return preferredRemote
    }
    if availableRemoteNames.contains("origin") {
        return "origin"
    }
    return availableRemoteNames.first
}

func pullRemoteBranchName(remote: String, branch: String) -> String? {
    let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRemote.isEmpty, !normalizedBranch.isEmpty else { return nil }
    return "\(normalizedRemote)/\(normalizedBranch)"
}

struct PullDialogOptions: Equatable, Sendable {
    let rebase: Bool
    let mode: MergeMode
    let noCommit: Bool
    let noVerify: Bool
}

struct PullDialogSelection: Equatable, Sendable {
    let rootPath: String
    let remote: String
    let remoteBranch: String
    let options: PullDialogOptions
}

/// SwiftUI counterpart of IntelliJ's GitPullDialog. Repository, remote and
/// remote-tracking branch are all selected explicitly; the action never falls
/// back to the current branch's configured upstream after the user chooses a
/// different branch.
struct PullDialogView: View {
    let snapshots: [GitRootBranchSnapshot]
    let defaultRootPath: String?
    let defaultRebase: Bool
    let initialOptions: Set<GitPullDialogOption>
    let blockedRootPaths: Set<String>
    let fetchInProgress: Bool
    let onCancel: () -> Void
    let onPull: (PullDialogSelection) -> Void
    let onFetch: (String, String) -> Void

    @State private var rootPath: String
    @State private var remoteName: String
    @State private var branchName: String
    @State private var selectedOptions: Set<GitPullDialogOption>

    init(
        snapshots: [GitRootBranchSnapshot],
        defaultRootPath: String?,
        defaultRebase: Bool,
        initialOptions: Set<GitPullDialogOption>,
        blockedRootPaths: Set<String> = [],
        fetchInProgress: Bool = false,
        onCancel: @escaping () -> Void,
        onPull: @escaping (PullDialogSelection) -> Void,
        onFetch: @escaping (String, String) -> Void
    ) {
        self.snapshots = snapshots
        self.defaultRootPath = defaultRootPath
        self.defaultRebase = defaultRebase
        self.initialOptions = initialOptions
        self.blockedRootPaths = blockedRootPaths
        self.fetchInProgress = fetchInProgress
        self.onCancel = onCancel
        self.onPull = onPull
        self.onFetch = onFetch

        let initialSnapshot = Self.resolveSnapshot(
            snapshots: snapshots,
            preferredRootPath: defaultRootPath
        )
        let initialRemote = Self.resolveRemoteName(for: initialSnapshot)
        let initialBranch = Self.resolveBranchName(
            for: initialSnapshot,
            remote: initialRemote
        )
        _rootPath = State(initialValue: initialSnapshot?.rootPath ?? defaultRootPath ?? "")
        _remoteName = State(initialValue: initialRemote)
        _branchName = State(initialValue: initialBranch)

        var options = initialOptions
        if defaultRebase {
            options.insert(.rebase)
        } else {
            options.remove(.rebase)
        }
        _selectedOptions = State(initialValue: options)
    }

    private var selectedSnapshot: GitRootBranchSnapshot? {
        snapshots.first { $0.rootPath == rootPath }
    }

    private var selectedRemote: RemoteInfo? {
        selectedSnapshot?.remotes.first { $0.name == remoteName }
    }

    private var remoteBranches: [RemoteBranchInfo] {
        selectedSnapshot?.remoteBranches
            .filter { $0.remote == remoteName }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ?? []
    }

    private var selectedRemoteBranch: RemoteBranchInfo? {
        remoteBranches.first { branchDisplayName($0) == branchName }
    }

    private var canPull: Bool {
        guard let snapshot = selectedSnapshot,
              snapshot.headBranch != nil,
              snapshot.headId != nil,
              selectedRemote != nil,
              selectedRemoteBranch != nil,
              !blockedRootPaths.contains(canonicalExternalLogPath(snapshot.rootPath)),
              !selectedOptions.contains(where: { !$0.isSuitable(with: selectedOptions) }) else {
            return false
        }
        return true
    }

    private var selectedOptionsSummary: String {
        let titles = GitPullDialogOption.allCases
            .filter { selectedOptions.contains($0) }
            .map(\.title)
        return titles.isEmpty ? "Default" : titles.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(defaultRebase ? "Pull with Rebase" : "Pull")
                .font(.title3)
                .bold()

            if snapshots.isEmpty {
                Label("No Git repository is available for Pull.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                if snapshots.count > 1 {
                    Picker("Repository", selection: $rootPath) {
                        ForEach(snapshots, id: \.rootPath) { snapshot in
                            Text(snapshot.relativePath == "." ? snapshot.displayName : snapshot.relativePath)
                                .tag(snapshot.rootPath)
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("git pull")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Picker("Remote", selection: $remoteName) {
                        ForEach(selectedSnapshot?.remotes ?? [], id: \.name) { remote in
                            Text(remote.name).tag(remote.name)
                        }
                    }
                    .frame(minWidth: 120)
                    Text("/")
                        .foregroundStyle(.secondary)
                    Picker("Branch", selection: $branchName) {
                        ForEach(remoteBranches, id: \.name) { branch in
                            Text(branchDisplayName(branch)).tag(branchDisplayName(branch))
                        }
                    }
                    .frame(minWidth: 220, maxWidth: .infinity)
                    Button("Fetch") {
                        onFetch(rootPath, remoteName)
                    }
                    .disabled(selectedRemote == nil || fetchInProgress)
                }

                if let snapshot = selectedSnapshot, snapshot.headBranch == nil {
                    Text("Pull requires the selected repository to be on a branch; detached HEAD is not supported.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let snapshot = selectedSnapshot, snapshot.headId == nil {
                    Text("Pull requires an existing HEAD commit; an unborn repository cannot be pulled yet.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if selectedRemoteBranch == nil {
                    Text("Select an existing remote-tracking branch.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let snapshot = selectedSnapshot,
                          blockedRootPaths.contains(canonicalExternalLogPath(snapshot.rootPath)) {
                    Text("The selected repository is busy with another Git operation.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if fetchInProgress {
                    Text("A Fetch operation is in progress; wait for it to finish before pulling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    HStack {
                        Label("Options", systemImage: "slider.horizontal.3")
                        Spacer()
                        Menu("Modify…") {
                            ForEach(GitPullDialogOption.allCases) { option in
                                Button {
                                    toggle(option)
                                } label: {
                                    if selectedOptions.contains(option) {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(option.title)
                                    }
                                }
                                .disabled(!option.isSuitable(with: selectedOptions))
                            }
                        }
                    }
                    Text(selectedOptionsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(defaultRebase ? "Pull with Rebase" : "Pull") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPull)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onChange(of: rootPath) { _, _ in
            reconcileSelection()
        }
        .onChange(of: remoteName) { _, _ in
            branchName = Self.resolveBranchName(for: selectedSnapshot, remote: remoteName)
        }
        .onChange(of: snapshots.map { "\($0.rootPath):\($0.remoteBranches.count):\($0.remotes.count)" }) { _, _ in
            reconcileSelection()
        }
    }

    private func toggle(_ option: GitPullDialogOption) {
        if selectedOptions.contains(option) {
            selectedOptions.remove(option)
        } else if option.isSuitable(with: selectedOptions) {
            selectedOptions.insert(option)
        }
    }

    private func submit() {
        guard canPull,
              let remoteBranch = selectedRemoteBranch,
              let fullName = pullRemoteBranchName(remote: remoteName, branch: branchDisplayName(remoteBranch)) else {
            return
        }
        let mode: MergeMode
        if selectedOptions.contains(.ffOnly) {
            mode = .fastForwardOnly
        } else if selectedOptions.contains(.noFF) {
            mode = .noFastForward
        } else if selectedOptions.contains(.squash) {
            mode = .squash
        } else {
            mode = .fastForward
        }
        onPull(
            PullDialogSelection(
                rootPath: rootPath,
                remote: remoteName,
                remoteBranch: fullName,
                options: PullDialogOptions(
                    rebase: selectedOptions.contains(.rebase),
                    mode: mode,
                    noCommit: selectedOptions.contains(.noCommit),
                    noVerify: selectedOptions.contains(.noVerify)
                )
            )
        )
    }

    private func reconcileSelection() {
        guard let snapshot = Self.resolveSnapshot(
            snapshots: snapshots,
            preferredRootPath: rootPath
        ) else {
            rootPath = ""
            remoteName = ""
            branchName = ""
            return
        }
        if rootPath != snapshot.rootPath {
            rootPath = snapshot.rootPath
        }
        if !snapshot.remotes.contains(where: { $0.name == remoteName }) {
            remoteName = Self.resolveRemoteName(for: snapshot)
        }
        if !remoteBranches.contains(where: { branchDisplayName($0) == branchName }) {
            branchName = Self.resolveBranchName(for: snapshot, remote: remoteName)
        }
    }

    private func branchDisplayName(_ branch: RemoteBranchInfo) -> String {
        let prefix = "(branch.remote)/"
        return branch.name.hasPrefix(prefix) ? String(branch.name.dropFirst(prefix.count)) : branch.name
    }

    private static func resolveSnapshot(
        snapshots: [GitRootBranchSnapshot],
        preferredRootPath: String?
    ) -> GitRootBranchSnapshot? {
        if let preferredRootPath,
           let preferred = snapshots.first(where: { $0.rootPath == preferredRootPath }) {
            return preferred
        }
        return snapshots.first
    }

    private static func resolveRemoteName(for snapshot: GitRootBranchSnapshot?) -> String {
        guard let snapshot else { return "" }
        let names = snapshot.remotes.map(\.name)
        let preferred = snapshot.syncStatuses.first(where: {
            snapshot.headBranch == $0.branch && $0.trackingExists
        })?.upstream.split(separator: "/", maxSplits: 1).first.map(String.init)
        return defaultPullRemoteName(preferredRemote: preferred, availableRemoteNames: names) ?? ""
    }

    private static func resolveBranchName(
        for snapshot: GitRootBranchSnapshot?,
        remote: String
    ) -> String {
        guard let snapshot else { return "" }
        let remoteBranches = snapshot.remoteBranches.filter { $0.remote == remote }
        let tracked = snapshot.syncStatuses.first(where: {
            snapshot.headBranch == $0.branch && $0.trackingExists && $0.upstream.hasPrefix("\(remote)/")
        })?.upstream.dropFirst(remote.count + 1).description
        if let tracked, remoteBranches.contains(where: { branchDisplayName($0) == tracked }) {
            return tracked
        }
        if let headBranch = snapshot.headBranch,
           remoteBranches.contains(where: { branchDisplayName($0) == headBranch }) {
            return headBranch
        }
        return remoteBranches.first.map {
            let prefix = "\($0.remote)/"
            return $0.name.hasPrefix(prefix) ? String($0.name.dropFirst(prefix.count)) : $0.name
        } ?? ""
    }

    private static func branchDisplayName(_ branch: RemoteBranchInfo) -> String {
        let prefix = "\(branch.remote)/"
        return branch.name.hasPrefix(prefix) ? String(branch.name.dropFirst(prefix.count)) : branch.name
    }
}
