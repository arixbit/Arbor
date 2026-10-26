import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BranchDashboardRemoteGroup: Hashable, Sendable {
    let rootPath: String
    let name: String
}
enum BranchDashboardRemoteGroupAction: String, Hashable, Sendable {
    case editRemote
    case removeRemote
}
struct BranchDashboardRemoteGroupActionAvailability: Equatable, Sendable {
    let actions: Set<BranchDashboardRemoteGroupAction>

    func contains(_ action: BranchDashboardRemoteGroupAction) -> Bool {
        actions.contains(action)
    }

    /// IntelliJ exposes Edit for one remote group and only Remove for a
    /// multi-selection. Each group remains a root-scoped target.
    static func resolve(
        selection: [BranchDashboardRemoteGroup]
    ) -> BranchDashboardRemoteGroupActionAvailability {
        switch selection.count {
        case 0:
            return BranchDashboardRemoteGroupActionAvailability(actions: [])
        case 1:
            return BranchDashboardRemoteGroupActionAvailability(
                actions: [.editRemote, .removeRemote]
            )
        default:
            return BranchDashboardRemoteGroupActionAvailability(actions: [.removeRemote])
        }
    }
}
/// IntelliJ Branches Popup 的 tracking 分支选择器。
struct SetUpstreamDialogView: View {
    let localBranch: String
    let repositoryName: String?
    let remoteBranches: [RemoteBranchInfo]
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var selectedUpstream: String

    init(
        localBranch: String,
        remoteBranches: [RemoteBranchInfo],
        currentUpstream: String?,
        repositoryName: String? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.localBranch = localBranch
        self.repositoryName = repositoryName
        self.remoteBranches = remoteBranches
        self.onCancel = onCancel
        self.onSave = onSave
        _selectedUpstream = State(initialValue: currentUpstream ?? remoteBranches.first?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Upstream").font(.title3.weight(.semibold))
            Text("为 \(localBranch) 选择一个 remote-tracking branch。")
                .foregroundStyle(.secondary)
            if let repositoryName, !repositoryName.isEmpty {
                Label(repositoryName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if remoteBranches.isEmpty {
                ContentUnavailableView {
                    Label("No remote branches", systemImage: "cloud.slash")
                } description: {
                    Text("Fetch the remote branch first, then set upstream.")
                }
            } else {
                Picker("Upstream", selection: $selectedUpstream) {
                    ForEach(remoteBranches, id: \.name) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Set Upstream") {
                    onSave(selectedUpstream)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedUpstream.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
/// Browse and delete tags from a selected remote without first importing them
/// into the local tag namespace. Listing and deletion both use the credential
/// broker because either operation can require authentication.
struct MultiRootRemoteTagRow: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let tag: RemoteTagInfo

    var id: String {
        "\(rootPath)::\(tag.remote)::\(tag.name)"
    }
}
func stableMultiRootRemoteTagRows(_ rows: [MultiRootRemoteTagRow]) -> [MultiRootRemoteTagRow] {
    rows.sorted {
        let left = [$0.relativePath, $0.tag.remote, $0.tag.name, $0.rootPath]
            .joined(separator: "\u{1F}")
        let right = [$1.relativePath, $1.tag.remote, $1.tag.name, $1.rootPath]
            .joined(separator: "\u{1F}")
        return left.localizedStandardCompare(right) == .orderedAscending
    }
}
func filteredMultiRootRemoteTagRows(
    _ rows: [MultiRootRemoteTagRow],
    query: String
) -> [MultiRootRemoteTagRow] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return rows }
    return rows.filter { row in
        [row.rootPath, row.displayName, row.relativePath, row.tag.remote, row.tag.name, row.tag.id]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
/// Browse and delete remote tags across all discovered Git roots. Every row
/// stays root-qualified because identical remote/tag names are independent
/// refs in IntelliJ's multi-repository model.
struct MultiRootRemoteTagsDialogView: View {
    let roots: [GitRootInfo]
    let broker: CredentialBroker
    let onResult: ([String], [String], Bool) -> Void
    let onDone: () -> Void

    @State private var rows: [MultiRootRemoteTagRow] = []
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var isDeleting = false
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var operationCancelHandle: GitCancelHandle?
    @State private var operationCancelling = false
    @State private var operationID = UUID()

    private var filteredRows: [MultiRootRemoteTagRow] {
        filteredMultiRootRemoteTagRows(rows, query: query)
    }

    private var allVisibleSelected: Bool {
        !filteredRows.isEmpty && filteredRows.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.blue)
                Text("Remote Tags Across Repositories")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    loadTags()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading || isDeleting)
                .help("Refresh remote tags across repositories")
            }

            HStack(spacing: 8) {
                TextField("Search remote tags", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button(allVisibleSelected ? "Clear Selection" : "Select Visible") {
                    if allVisibleSelected {
                        selectedIDs.subtract(filteredRows.map(\.id))
                    } else {
                        selectedIDs.formUnion(filteredRows.map(\.id))
                    }
                }
                .controlSize(.small)
                .disabled(filteredRows.isEmpty || isLoading || isDeleting)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let resultText {
                Label(resultText, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading remote tags…")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if filteredRows.isEmpty {
                ContentUnavailableView(
                    "No Remote Tags",
                    systemImage: "tag.slash",
                    description: Text("No matching remote tags were found in the discovered repositories.")
                )
            } else {
                List(filteredRows) { row in
                    Toggle(isOn: selectionBinding(for: row.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "tag")
                                    .foregroundStyle(.secondary)
                                Text(row.tag.name)
                                    .lineLimit(1)
                                Text(remoteTagKindLabel(row.tag.kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(row.relativePath) · \(row.tag.remote)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.tag.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(selectedIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    Button(operationCancelling ? "Canceling…" : "Cancel") {
                        cancelOperation()
                    }
                    .disabled(operationCancelling)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                    Button("Delete Selected", role: .destructive) {
                        deleteSelected()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
        .onAppear(perform: loadTags)
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }

    private func loadTags() {
        guard !isDeleting else { return }
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        isLoading = true
        errorText = nil
        resultText = nil
        let roots = roots
        let broker = broker
        Task.detached(priority: .userInitiated) {
            var loadedRows: [MultiRootRemoteTagRow] = []
            var failures: [String] = []
            var cancelled = false
            rootLoop: for root in roots {
                if cancelHandle.isCancelled() {
                    cancelled = true
                    break
                }
                do {
                    let repo = try openRepository(path: root.path)
                    for remote in try repo.remoteList() {
                        if cancelHandle.isCancelled() {
                            cancelled = true
                            break rootLoop
                        }
                        do {
                            let tags = try repo.remoteTagListWithAuthAndCancel(
                                remote: remote.name,
                                broker: broker,
                                cancel: cancelHandle
                            )
                            loadedRows.append(contentsOf: tags.map { tag in
                                MultiRootRemoteTagRow(
                                    rootPath: root.path,
                                    displayName: root.displayName,
                                    relativePath: root.relativePath,
                                    tag: tag
                                )
                            })
                        } catch {
                            if cancelHandle.isCancelled() {
                                cancelled = true
                                break rootLoop
                            }
                            failures.append("\(root.relativePath) · \(remote.name): \(error)")
                        }
                    }
                } catch {
                    if cancelHandle.isCancelled() {
                        cancelled = true
                        break
                    }
                    failures.append("\(root.relativePath): \(error)")
                }
            }
            let sortedRows = stableMultiRootRemoteTagRows(loadedRows)
            let loadErrorText = failures.isEmpty
                ? nil
                : "Some repositories or remotes could not be loaded: " + failures.joined(separator: " | ")
            let wasCancelled = cancelled
            await MainActor.run {
                guard self.operationID == operationID else { return }
                self.rows = sortedRows
                self.selectedIDs = self.selectedIDs.intersection(Set(sortedRows.map(\.id)))
                self.isLoading = false
                self.operationCancelHandle = nil
                self.operationCancelling = false
                self.errorText = wasCancelled
                    ? String(localized: "Remote tag operation canceled.")
                    : loadErrorText
            }
        }
    }

    private func deleteSelected() {
        let selectedRows = rows.filter { selectedIDs.contains($0.id) }
        guard !selectedRows.isEmpty else { return }
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        isDeleting = true
        isLoading = true
        errorText = nil
        resultText = nil
        let broker = broker
        Task.detached(priority: .userInitiated) {
            var successes: [String] = []
            var failures: [String] = []
            var completedIDs: Set<String> = []
            var cancelled = false
            rowLoop: for row in selectedRows {
                if cancelHandle.isCancelled() {
                    cancelled = true
                    break
                }
                let label = "\(row.relativePath) · \(row.tag.remote)/\(row.tag.name)"
                do {
                    let repo = try openRepository(path: row.rootPath)
                    let deleted = try repo.deleteRemoteTagWithAuthLeaseAndCancel(
                        remote: row.tag.remote,
                        tag: row.tag.name,
                        expectedObjectId: row.tag.objectId,
                        broker: broker,
                        cancel: cancelHandle
                    )
                    if deleted {
                        successes.append(label)
                        completedIDs.insert(row.id)
                    } else {
                        failures.append("\(label): already absent")
                        completedIDs.insert(row.id)
                    }
                } catch {
                    if cancelHandle.isCancelled() {
                        cancelled = true
                        break rowLoop
                    }
                    failures.append("\(label): \(error)")
                }
            }
            let completedSuccesses = successes
            let completedFailures = failures
            let completedRowIDs = completedIDs
            let wasCancelled = cancelled
            let resultText = "Deleted \(completedSuccesses.count) remote tag(s)."
                + (completedFailures.isEmpty ? "" : " Failed \(completedFailures.count): " + completedFailures.joined(separator: " | "))
            await MainActor.run {
                guard self.operationID == operationID else { return }
                self.isDeleting = false
                self.isLoading = false
                self.operationCancelHandle = nil
                self.operationCancelling = false
                self.selectedIDs.subtract(completedRowIDs)
                self.resultText = wasCancelled
                    ? String(localized: "Remote tag deletion canceled; completed changes were kept.")
                    : resultText
                self.onResult(completedSuccesses, completedFailures, wasCancelled)
                if !wasCancelled {
                    self.loadTags()
                }
            }
        }
    }

    private func cancelOperation() {
        guard isLoading, !operationCancelling else { return }
        operationCancelling = true
        operationCancelHandle?.cancel()
    }

    private func remoteTagKindLabel(_ kind: TagKind) -> String {
        switch kind {
        case .lightweight: "Lightweight"
        case .annotated: "Annotated"
        case .signed: "Signed"
        }
    }
}
struct RemoteTagsDialogView: View {
    let repo: Repository
    let broker: CredentialBroker
    let remotes: [RemoteInfo]
    let onDeleted: (String, String) -> Void
    let onDone: () -> Void

    @State private var selectedRemote: String
    @State private var remoteTags: [RemoteTagInfo] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var pendingDelete: RemoteTagInfo?
    @State private var operationCancelHandle: GitCancelHandle?
    @State private var operationCancelling = false
    @State private var operationID = UUID()

    init(
        repo: Repository,
        broker: CredentialBroker,
        remotes: [RemoteInfo],
        onDeleted: @escaping (String, String) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.repo = repo
        self.broker = broker
        self.remotes = remotes
        self.onDeleted = onDeleted
        self.onDone = onDone
        _selectedRemote = State(
            initialValue: resolveSelectedRemoteName(
                selectedRemote: nil,
                availableRemoteNames: remotes.map(\.name)
            ) ?? ""
        )
    }

    private var filteredTags: [RemoteTagInfo] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return remoteTags }
        return remoteTags.filter { $0.name.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.blue)
                Text("Remote Tags")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    loadTags()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading || selectedRemote.isEmpty)
                .help("Refresh remote tags")
            }

            Picker("Remote", selection: $selectedRemote) {
                Text("Select a remote…").tag("")
                ForEach(remotes, id: \.name) { remote in
                    Text(remote.name).tag(remote.name)
                }
            }
            .onChange(of: selectedRemote) { _, _ in
                loadTags()
            }

            TextField("Search remote tags", text: $query)
                .textFieldStyle(.roundedBorder)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading remote tags…")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if filteredTags.isEmpty {
                ContentUnavailableView(
                    "No Remote Tags",
                    systemImage: "tag.slash",
                    description: Text("The selected remote has no matching tags.")
                )
            } else {
                List(filteredTags, id: \.name) { tag in
                    HStack(spacing: 8) {
                        Image(systemName: "tag")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.name)
                                .lineLimit(1)
                            Text(tag.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(remoteTagKindLabel(tag.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Delete", role: .destructive) {
                            pendingDelete = tag
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                if isLoading {
                    Button(operationCancelling ? "Canceling…" : "Cancel") {
                        cancelOperation()
                    }
                    .disabled(operationCancelling)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 500)
        .onAppear {
            loadTags()
        }
        .alert(
            "Delete Remote Tag?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { isPresented in
                    if !isPresented { pendingDelete = nil }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let tag = pendingDelete else { return }
                pendingDelete = nil
                deleteTag(tag)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let pendingDelete {
                Text(verbatim: pendingDelete.name + " · " + pendingDelete.remote)
            }
        }
    }

    private func loadTags() {
        let remote = selectedRemote
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        guard !remote.isEmpty else {
            remoteTags = []
            operationCancelHandle = nil
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        Task.detached(priority: .userInitiated) {
            do {
                let tags = try repo.remoteTagListWithAuthAndCancel(
                    remote: remote,
                    broker: broker,
                    cancel: cancelHandle
                )
                await MainActor.run {
                    guard self.operationID == operationID,
                          self.selectedRemote == remote else { return }
                    self.remoteTags = tags
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                }
            } catch {
                await MainActor.run {
                    guard self.operationID == operationID,
                          self.selectedRemote == remote else { return }
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                    self.errorText = cancelHandle.isCancelled()
                        ? String(localized: "Remote tag operation canceled.")
                        : String(describing: error)
                }
            }
        }
    }

    private func deleteTag(_ tag: RemoteTagInfo) {
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        isLoading = true
        errorText = nil
        let remote = tag.remote
        Task.detached(priority: .userInitiated) {
            var didDelete = false
            do {
                didDelete = try repo.deleteRemoteTagWithAuthLeaseAndCancel(
                    remote: remote,
                    tag: tag.name,
                    expectedObjectId: tag.objectId,
                    broker: broker,
                    cancel: cancelHandle
                )
                guard !cancelHandle.isCancelled() else {
                    let completedDelete = didDelete
                    await MainActor.run {
                        guard self.operationID == operationID else { return }
                        self.isLoading = false
                        self.operationCancelHandle = nil
                        self.operationCancelling = false
                        self.errorText = completedDelete
                            ? String(localized: "Remote tag deletion canceled; completed changes were kept.")
                            : String(localized: "Remote tag operation canceled.")
                    }
                    return
                }
                let tags = try repo.remoteTagListWithAuthAndCancel(
                    remote: remote,
                    broker: broker,
                    cancel: cancelHandle
                )
                let completedDelete = didDelete
                await MainActor.run {
                    guard self.operationID == operationID,
                          self.selectedRemote == remote else { return }
                    self.remoteTags = tags
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                    if completedDelete {
                        self.onDeleted(remote, tag.name)
                    } else {
                        self.errorText = "The remote tag was already absent."
                    }
                }
            } catch {
                let completedDelete = didDelete
                await MainActor.run {
                    guard self.operationID == operationID else { return }
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                    if cancelHandle.isCancelled() {
                        if completedDelete {
                            self.remoteTags.removeAll { $0.name == tag.name }
                        }
                        self.errorText = completedDelete
                            ? String(localized: "Remote tag deletion canceled; completed changes were kept.")
                            : String(localized: "Remote tag operation canceled.")
                    } else {
                        self.errorText = String(describing: error)
                    }
                }
            }
        }
    }

    private func cancelOperation() {
        guard isLoading, !operationCancelling else { return }
        operationCancelling = true
        operationCancelHandle?.cancel()
    }

    private func remoteTagKindLabel(_ kind: TagKind) -> String {
        switch kind {
        case .lightweight: "Lightweight"
        case .annotated: "Annotated"
        case .signed: "Signed"
        }
    }
}
struct RebasedMultiRootRemoteDeleteBranchDialog: View {
    let remoteBranch: String
    @Binding var selectedRootPaths: Set<String>
    @Binding var deleteTracking: Bool
    let snapshots: [GitRootBranchSnapshot]
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var eligibleSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.remoteBranches.contains { $0.name == remoteBranch }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !eligibleSnapshots.isEmpty
            && eligibleSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private var commonTrackingBranches: [String] {
        let selected = eligibleSnapshots.filter { selectedRootPaths.contains($0.rootPath) }
        guard let first = selected.first else { return [] }
        let initial = Set(
            first.syncStatuses
                .filter { $0.upstream == remoteBranch && $0.trackingExists }
                .map(\.branch)
        )
        let intersection = selected.dropFirst().reduce(initial) { common, snapshot in
            common.intersection(
                snapshot.syncStatuses
                    .filter { $0.upstream == remoteBranch && $0.trackingExists }
                    .map(\.branch)
            )
        }
        let currentBranches = Set(selected.compactMap(\.headBranch))
        return intersection.subtracting(currentBranches).sorted()
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Remote Branch")
                .font(.title3.weight(.semibold))
            Text("Delete \(remoteBranch) from Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This deletes the branch from the remote repository in every selected root.")
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(eligibleSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(eligibleSnapshots, id: \.rootPath) { snapshot in
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 170)
            if !commonTrackingBranches.isEmpty {
                Toggle(
                    "Also delete common local tracking branches",
                    isOn: $deleteTracking
                )
                .toggleStyle(.checkbox)
                Text(commonTrackingBranches.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if eligibleSnapshots.isEmpty {
                Text("No repository contains this remote branch.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("\(selectedRootPaths.count) repositories selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
                    .disabled(eligibleSnapshots.isEmpty || selectedRootPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
/// Git 项目生命周期入口：把 Rebased 的 Clone 作为项目管理的一等操作，
/// 而不是要求用户先在终端完成 clone 再回到 Arbor 打开目录。
struct RebasedRemoteBranchSelectionDialog: View {
    let commits: [CommitInfo]
    let remoteBranches: [RemoteBranchInfo]
    let onCancel: () -> Void
    let onSelect: (RemoteBranchInfo) -> Void

    @State private var selectedBranch: String

    init(
        commits: [CommitInfo],
        remoteBranches: [RemoteBranchInfo],
        onCancel: @escaping () -> Void,
        onSelect: @escaping (RemoteBranchInfo) -> Void
    ) {
        self.commits = commits
        self.remoteBranches = remoteBranches
        self.onCancel = onCancel
        self.onSelect = onSelect
        _selectedBranch = State(initialValue: remoteBranches.first?.name ?? "")
    }

    private var selectedRemoteBranch: RemoteBranchInfo? {
        remoteBranches.first { $0.name == selectedBranch }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Commits to Remote Branch")
                .font(.title3)
                .bold()
            Text("Fetch the selected remote branch, replay the selected commits in memory, then open Push with the new detached tip.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Remote branch", selection: $selectedBranch) {
                ForEach(remoteBranches, id: \.name) { branch in
                    Text("\(branch.name) · \(branch.shortId)").tag(branch.name)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 6) {
                Text("Commits")
                    .font(.headline)
                ForEach(commits.prefix(20), id: \.id) { commit in
                    HStack(spacing: 7) {
                        Text(commit.shortId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(commit.summary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                if commits.count > 20 {
                    Text("\(commits.count - 20) more commits…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Continue") {
                    if let selectedRemoteBranch {
                        onSelect(selectedRemoteBranch)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRemoteBranch == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
/// REMOTE-001：Configure Remotes Dialog。
/// 远程列表 + URL / push URL / fetch refspec / push refspec 编辑 + 添加/删除/重命名。
struct RemoteConfigDialogView: View {
    let remotes: [RemoteInfo]
    @Binding var name: String
    @Binding var url: String
    @Binding var pushUrl: String
    @Binding var fetchRefspec: String
    @Binding var pushRefspec: String
    let initialSelectedName: String?
    @State private var selectedName: String?
    let onAdd: (Bool) -> Void
    let onRemove: (String) -> Void
    let onRename: (String, String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onRefresh: () -> Void
    @State private var fetchAfterAdd = true

    private var remoteNamesKey: String {
        remotes.map(\.name).joined(separator: "\u{1F}")
    }

    private func populate(_ remote: RemoteInfo) {
        name = remote.name
        url = remote.url
        pushUrl = remote.pushUrl ?? ""
        fetchRefspec = remote.fetchRefspec ?? ""
        pushRefspec = remote.pushRefspec ?? ""
    }

    private func clearFields() {
        name = ""
        url = ""
        pushUrl = ""
        fetchRefspec = ""
        pushRefspec = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Remotes").font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { onRefresh() }
                Button("Cancel", role: .cancel, action: onCancel)
            }
            HStack(spacing: 0) {
                List(remotes, id: \.name, selection: $selectedName) { remote in
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(remote.name).font(.system(size: 13, weight: .semibold))
                            Text(remote.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(remote.name)
                }
                .listStyle(.sidebar)
                .frame(width: 240)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let selected = selectedName, let remote = remotes.first(where: { $0.name == selected }) {
                        Group {
                            Text("Name")
                            TextField("name", text: Binding(get: { name }, set: { name = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Text("URL")
                            TextField("https://…", text: $url)
                                .textFieldStyle(.roundedBorder)
                            Text("Push URL (optional)")
                            TextField("https://…", text: $pushUrl)
                                .textFieldStyle(.roundedBorder)
                            Text("Fetch refspec")
                            TextField("+refs/heads/*:refs/remotes/origin/*", text: $fetchRefspec)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Text("Push refspec (optional)")
                            TextField("HEAD:refs/heads/main", text: $pushRefspec)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Remove") { onRemove(remote.name) }
                            Button("Rename…") {
                                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                    name = remote.name
                                }
                                onRename(remote.name, name)
                                selectedName = name.trimmingCharacters(in: .whitespaces)
                            }
                            Spacer()
                            Button("Save") { onSave() }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text("Select a remote to edit")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                Text("New remote")
                    .foregroundStyle(.secondary)
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
                Toggle("Fetch after adding", isOn: $fetchAfterAdd)
                    .toggleStyle(.checkbox)
                Button("Add") { onAdd(fetchAfterAdd) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 420)
        .onAppear {
            let initial = selectedName.flatMap { selected in
                remotes.first(where: { $0.name == selected })
            } ?? initialSelectedName.flatMap { selected in
                remotes.first(where: { $0.name == selected })
            }
            if selectedName == nil {
                selectedName = initial?.name
            }
            if let initial {
                populate(initial)
            } else {
                clearFields()
            }
        }
        .onChange(of: selectedName) { _, newValue in
            guard let newValue, let remote = remotes.first(where: { $0.name == newValue }) else { return }
            populate(remote)
        }
        .onChange(of: remoteNamesKey) { _, _ in
            let selected = selectedName.flatMap { selected in
                remotes.first(where: { $0.name == selected })
            }
            selectedName = selected?.name
            if let selected {
                populate(selected)
            } else {
                clearFields()
            }
        }
    }
}
private struct MultiRootRemoteEditorContext: Identifiable {
    let id = UUID()
    let rootPath: String
    let originalName: String?
    let isAdd: Bool
    let name: String
    let url: String
    let pushURL: String
    let fetchRefspec: String
    let pushRefspec: String
}
private struct MultiRootRemoteConfigEditorView: View {
    let context: MultiRootRemoteEditorContext
    let onSubmit: (String, String, String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var pushURL: String
    @State private var fetchRefspec: String
    @State private var pushRefspec: String
    @State private var fetchAfterSave = true
    @State private var validationMessage: String?
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case url
    }

    init(
        context: MultiRootRemoteEditorContext,
        onSubmit: @escaping (String, String, String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    ) {
        self.context = context
        self.onSubmit = onSubmit
        _name = State(initialValue: context.name)
        _url = State(initialValue: context.url)
        _pushURL = State(initialValue: context.pushURL)
        _fetchRefspec = State(initialValue: context.fetchRefspec)
        _pushRefspec = State(initialValue: context.pushRefspec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(context.isAdd ? "Add Remote" : "Edit Remote")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                TextField("URL", text: $url)
                    .focused($focusedField, equals: .url)
                Toggle("Fetch after saving", isOn: $fetchAfterSave)
                    .toggleStyle(.checkbox)
                if !context.isAdd {
                    DisclosureGroup("Advanced") {
                        TextField("Push URL (optional)", text: $pushURL)
                        TextField("Fetch refspec", text: $fetchRefspec)
                            .font(.system(.body, design: .monospaced))
                        TextField("Push refspec (optional)", text: $pushRefspec)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isSubmitting)
                Button(context.isAdd ? "Add" : "Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    validationMessage = nil
                    guard !trimmedName.isEmpty else {
                        validationMessage = localizedArborString("Remote name is required", locale: AppLanguage.interfaceLocale)
                        focusedField = .name
                        return
                    }
                    guard !trimmedURL.isEmpty else {
                        validationMessage = localizedArborString("Remote URL is required", locale: AppLanguage.interfaceLocale)
                        focusedField = .url
                        return
                    }
                    isSubmitting = true
                    onSubmit(
                        trimmedName,
                        trimmedURL,
                        pushURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        fetchRefspec.trimmingCharacters(in: .whitespacesAndNewlines),
                        pushRefspec.trimmingCharacters(in: .whitespacesAndNewlines),
                        fetchAfterSave
                    ) { success in
                        isSubmitting = false
                        if success {
                            dismiss()
                        } else {
                            validationMessage = localizedArborString("Remote URL check failed; see the operation feedback for details.", locale: AppLanguage.interfaceLocale)
                            focusedField = .url
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}
/// IntelliJ 的 GitConfigureRemotesDialog：按 Git root 分组展示 remote，
/// Add 使用当前 root，Edit/Remove 使用选中的 remote，双击 remote 进入编辑。
struct MultiRootRemoteConfigDialogView: View {
    let roots: [MultiRootRemoteConfigRoot]
    let onAdd: (String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    let onEdit: (String, String, String, String, String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    let onRemove: (String, String) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void
    @State private var selectedID: String?
    @State private var selectedRootPath: String?
    @State private var editor: MultiRootRemoteEditorContext?

    private func selectionID(rootPath: String, remoteName: String) -> String {
        "\(rootPath)\u{1F}\(remoteName)"
    }

    private func selectedRoot() -> MultiRootRemoteConfigRoot? {
        if let selectedRootPath, let root = roots.first(where: { $0.rootPath == selectedRootPath }) {
            return root
        }
        guard let selectedID else { return roots.first }
        return roots.first { root in
            selectedID == root.rootPath || selectedID.hasPrefix(root.rootPath + "\u{1F}")
        } ?? roots.first
    }

    private func selectedRemote() -> (MultiRootRemoteConfigRoot, RemoteInfo)? {
        guard let selectedID else { return nil }
        for root in roots {
            if let remote = root.remotes.first(where: {
                selectedID == selectionID(rootPath: root.rootPath, remoteName: $0.name)
            }) {
                return (root, remote)
            }
        }
        return nil
    }

    private func openAdd() {
        guard let root = selectedRoot() else { return }
        let proposedName = root.remotes.contains(where: { $0.name == "origin" }) ? "" : "origin"
        editor = MultiRootRemoteEditorContext(
            rootPath: root.rootPath,
            originalName: nil,
            isAdd: true,
            name: proposedName,
            url: "",
            pushURL: "",
            fetchRefspec: "",
            pushRefspec: ""
        )
    }

    private func openEdit(root: MultiRootRemoteConfigRoot, remote: RemoteInfo) {
        editor = MultiRootRemoteEditorContext(
            rootPath: root.rootPath,
            originalName: remote.name,
            isAdd: false,
            name: remote.name,
            url: remote.url,
            pushURL: remote.pushUrl ?? "",
            fetchRefspec: remote.fetchRefspec ?? "",
            pushRefspec: remote.pushRefspec ?? ""
        )
    }

    private func openEdit() {
        guard let (root, remote) = selectedRemote() else { return }
        openEdit(root: root, remote: remote)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Configure Remotes")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { onRefresh() }
                Button("Done", role: .cancel, action: onCancel)
            }
            List(selection: $selectedID) {
                ForEach(roots) { root in
                    Section {
                        if root.remotes.isEmpty {
                            Text("No remotes")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(root.remotes, id: \.name) { remote in
                                HStack(spacing: 8) {
                                    Text(remote.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer(minLength: 12)
                                    Text(remote.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .tag(selectionID(rootPath: root.rootPath, remoteName: remote.name))
                                .onTapGesture(count: 2) {
                                    selectedID = selectionID(rootPath: root.rootPath, remoteName: remote.name)
                                    openEdit(root: root, remote: remote)
                                }
                            }
                        }
                    } header: {
                        Button {
                            selectedRootPath = root.rootPath
                            selectedID = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
            HStack(spacing: 8) {
                Button("Add") { openAdd() }
                Button("Edit…") { openEdit() }
                    .disabled(selectedRemote() == nil)
                Button("Remove") {
                    guard let (root, remote) = selectedRemote() else { return }
                    onRemove(root.rootPath, remote.name)
                }
                .disabled(selectedRemote() == nil)
                Spacer()
                Text("\(roots.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            if selectedRootPath == nil {
                selectedRootPath = roots.first?.rootPath
            }
        }
        .onChange(of: selectedID) { _, newValue in
            guard let newValue else { return }
            selectedRootPath = roots.first { root in
                newValue == root.rootPath || newValue.hasPrefix(root.rootPath + "\u{1F}")
            }?.rootPath
        }
        .onChange(of: roots.map(\.rootPath)) { _, _ in
            if selectedRootPath == nil || !roots.contains(where: { $0.rootPath == selectedRootPath }) {
                selectedRootPath = roots.first?.rootPath
            }
        }
        .sheet(item: $editor) { context in
            MultiRootRemoteConfigEditorView(context: context) { name, url, pushURL, fetchRefspec, pushRefspec, fetchAfterSave, completion in
                if context.isAdd {
                    onAdd(context.rootPath, name, url, fetchAfterSave, completion)
                } else if let originalName = context.originalName {
                    onEdit(
                        context.rootPath,
                        originalName,
                        name,
                        url,
                        pushURL,
                        fetchRefspec,
                        pushRefspec,
                        fetchAfterSave,
                        completion
                    )
                }
            }
        }
    }
}
