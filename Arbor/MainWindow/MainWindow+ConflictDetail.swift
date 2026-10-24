import SwiftUI
import AppKit


// MARK: - 冲突三栏视图（可编辑）

func isCurrentConflictLoadRequest(
    repositoryID: String,
    path: String,
    generation: Int,
    currentRepositoryID: String?,
    currentPath: String,
    currentGeneration: Int
) -> Bool {
    repositoryID == currentRepositoryID
        && path == currentPath
        && generation == currentGeneration
}

struct ConflictDetailView: View {
    let repo: Repository?
    let path: String
    let onChanged: () -> Void
    /// Direct Apply Patch conflicts use the same Git conflict stages, but the
    /// second side is the patch rather than a branch or shelf. Keep the
    /// original effective patch available for an IntelliJ-style preview.
    let patchText: String?
    /// Restore snapshot name used to persist per-hunk Apply Patch decisions.
    let restoreName: String?

    init(
        repo: Repository?,
        path: String,
        patchText: String? = nil,
        restoreName: String? = nil,
        onChanged: @escaping () -> Void
    ) {
        self.repo = repo
        self.path = path
        self.patchText = patchText
        self.restoreName = restoreName
        self.onChanged = onChanged
    }

    @State var conflict: ConflictFile?
    @State var conflictBatchPreview: ConflictBatchPreview?
    @State var conflictIsBinary = false
    @State var operationKind: OperationKind?
    @State var mergeSourceReference: String?
    @State var conflictError: String?
    @State var feedback: String?
    @State var feedbackIsSuccess = false
    @State var saving = false
    @State var externalToolWorking = false
    @State var externalToolCancelling = false
    @State var externalToolCancelHandle: GitCancelHandle?
    @State var showExternalToolSettings = false
    @State var selectedBlock = 0
    @State var patchHunks: [ApplyPatchConflictHunk] = []
    @State var selectedPatchHunkID: String?
    @State var showBase = false
    @State var showPatchPreview = false
    @State var showLocalDiff = false
    @State var patchPreviewPresentationMode: DiffPresentationMode = .sideBySide
    @State var localDiffPresentationMode: DiffPresentationMode = .sideBySide
    @State var localDiff: FileDiff?
    @State var localDiffLoading = false
    @State var localDiffError: String?
    @State var showPartialResolveConfirmation = false
    @State var pendingResolveContent: String?
    @State var reloadToken = 0
    @State var loadGeneration = 0
    @StateObject var bridge = MergeEditorBridge()

    var isPatchMode: Bool { patchText != nil }

    /// Git's ours/theirs sides keep the same names in every operation, but
    /// their meaning changes: ours is the current branch during a merge and
    /// the upstream during a rebase; theirs is the incoming commit. Label the
    /// panes by operation instead of calling one side "Remote", which is
    /// wrong for rebase, cherry-pick, revert and stash restore.
    var oursSideTitle: String {
        switch operationKind {
        case .rebase: return String(localized: "Upstream (ours)")
        case .merge, .cherryPick, .revert: return String(localized: "Current branch (ours)")
        default: return String(localized: "Ours")
        }
    }

    var theirsSideTitle: String {
        switch operationKind {
        case .rebase: return String(localized: "Your commit (theirs)")
        case .merge:
            if let source = mergeSourceReference, !source.isEmpty {
                return String(localized: "%@ (theirs)")
                    .replacingOccurrences(of: "%@", with: source)
            }
            return String(localized: "Merged branch (theirs)")
        case .cherryPick: return String(localized: "Picked commit (theirs)")
        case .revert: return String(localized: "Reverted commit (theirs)")
        default: return String(localized: "Theirs")
        }
    }

    var selectedPatchHunk: ApplyPatchConflictHunk? {
        guard isPatchMode else { return nil }
        return patchHunks.first { $0.id == selectedPatchHunkID }
    }

    var editorSelectedPatchHunk: ApplyPatchConflictHunk? {
        guard isPatchMode else { return nil }
        return patchHunks.first { bridge.isHunkSelected($0) }
    }

    var editorSelectedPatchHunks: [ApplyPatchConflictHunk] {
        guard isPatchMode else { return [] }
        return patchHunks.filter { bridge.isHunkSelected($0) }
    }

    var actionPatchHunks: [ApplyPatchConflictHunk] {
        if !editorSelectedPatchHunks.isEmpty {
            return editorSelectedPatchHunks
        }
        return selectedPatchHunk.map { [$0] } ?? []
    }

    var unresolvedPatchHunks: [ApplyPatchConflictHunk] {
        patchHunks.filter { !$0.resolution.isResolved }
    }

    var patchPreviewDiff: FileDiff? {
        guard let patchText else { return nil }
        let file = RebasedUnshelveDialog.parsePatchFiles(
            patchText,
            allowedPaths: [path]
        ).first { $0.path == path }
        guard let file else { return nil }
        return RebasedPatchDiffParser.parse(patch: file.rawPatch, path: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isPatchMode ? "Patch conflict: \(path)" : "Conflict: \(path)")
                    .font(.headline).lineLimit(1)
                Spacer()
                if patchText != nil {
                    Button("Patch") { showPatchPreview = true }
                        .help("View the actual patch for this Apply Patch conflict")
                    Button("Local Diff") { loadLocalDiff() }
                        .help("Compare the local conflict stage with the current result editor")
                }
                Button("Reset") { resetConflictFile() }
                    .help("Regenerate conflict markers from the index stages and clear this file's hunk decisions")
                    .disabled(conflict == nil || conflictIsBinary || saving)
                if !isPatchMode {
                    Button("Accept Both") { acceptFile(.both) }
                        .help("Keep both sides (ours first)")
                        .disabled(conflict == nil || conflictIsBinary)
                    Button("Base") { showBase = true }
                        .help("View the common ancestor")
                        .disabled(conflict == nil || conflictIsBinary)
                    Button(externalToolWorking ? (externalToolCancelling ? "Canceling…" : "Cancel") : "External Tool") {
                        if externalToolWorking {
                            externalToolCancelling = true
                            externalToolCancelHandle?.cancel()
                        } else {
                            openExternalTool()
                        }
                    }
                    .help("Run Git's configured external merge tool")
                    .disabled(
                        externalToolCancelling
                            || saving
                            || repo == nil
                            || conflict == nil
                    )
                    Button("Settings…") { showExternalToolSettings = true }
                        .disabled(repo == nil || externalToolWorking || saving)
                }
                Button("Refresh") { load() }
                Button(saving ? "Saving…" : "Mark Resolved") { markResolved() }
                    .disabled(saving || repo == nil || conflict == nil || conflictIsBinary)
            }
            .padding(10)
            Divider()
            if let conflictError {
                Text(conflictError).foregroundStyle(.red).padding()
                Spacer()
            } else if conflict == nil, let feedback {
                Label(feedback, systemImage: feedbackIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(feedbackIsSuccess ? .green : .red)
                    .padding()
                Spacer()
            } else if conflictIsBinary {
                binaryConflictView
            } else if let conflict {
                MergeEditorView(ours: conflict.ours, theirs: conflict.theirs,
                                initialResult: conflict.result, path: path, bridge: bridge,
                                patchText: patchText,
                                patchHunks: patchHunks,
                                oursTitle: oursSideTitle,
                                theirsTitle: theirsSideTitle,
                                onSelectPatchHunk: { selectedPatchHunkID = $0.id },
                                onApplyPatchHunk: { applySelectedPatchHunk($0) },
                                onCopyPatchHunk: { copyPatchHunk($0) },
                                onIgnorePatchHunk: { ignoreSelectedPatchHunk($0) },
                                reloadToken: reloadToken)
                Divider()
                if isPatchMode {
                    applyPatchToolbar
                } else {
                    blockToolbar
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: repo?.gitDir()) { _, _ in load() }
        .onChange(of: bridge.blocks.count) { _, n in
            if selectedBlock >= n { selectedBlock = max(0, n - 1) }
        }
        .onChange(of: bridge.resultRevision) { _, _ in
            if isPatchMode { refreshUnresolvedPatchHunks() }
        }
        .onChange(of: bridge.selectionRevision) { _, _ in
            guard isPatchMode, let hunk = editorSelectedPatchHunk else { return }
            if selectedPatchHunkID != hunk.id {
                selectedPatchHunkID = hunk.id
            }
            bridge.revealPatchHunk(hunk)
        }
        .onChange(of: selectedPatchHunkID) { _, _ in
            guard isPatchMode, let hunk = selectedPatchHunk else { return }
            bridge.revealPatchHunk(hunk)
        }
        .sheet(isPresented: $showBase) { baseSheet }
        .sheet(isPresented: $showPatchPreview) { patchPreviewSheet }
        .sheet(isPresented: $showLocalDiff) { localDiffSheet }
        .sheet(isPresented: $showExternalToolSettings) {
            if let repo {
                GitMergeToolSettingsView(
                    repo: repo,
                    onSaved: { showExternalToolSettings = false },
                    onCancel: { showExternalToolSettings = false }
                )
            }
        }
        .alert("Patch changes remain unresolved", isPresented: $showPartialResolveConfirmation) {
            Button("Finish Anyway", role: .destructive) {
                let content = pendingResolveContent
                pendingResolveContent = nil
                guard let content else { return }
                resolveEditedContent(content, allowConflictMarkers: true)
            }
            Button("Continue Editing", role: .cancel) {
                pendingResolveContent = nil
            }
        } message: {
            Text("\(unresolvedPatchHunks.count) patch change(s) are still unresolved. Finish the file anyway, or continue editing.")
        }
    }

    var binaryConflictView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Binary Conflict", systemImage: "doc.badge.gearshape")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(isPatchMode
                 ? "This file cannot be merged in the text editor. Keep the local file or apply the complete patch side."
                 : "This file cannot be merged in the text editor. Choose which complete version to keep.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(isPatchMode ? "Keep Local" : "Accept Ours") { acceptFile(.ours) }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                Button(isPatchMode ? "Apply Patch" : "Accept Theirs") { acceptFile(.theirs) }
                    .buttonStyle(.bordered)
                    .disabled(saving)
            }
            Text("Accept Both, Reset, manual editing, and Base are unavailable for binary conflicts to avoid corrupting the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    var blockToolbar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Accept All Ours") { acceptAllBlocks(.ours) }
                    Button("Accept All Theirs") { acceptAllBlocks(.theirs) }
                    Button("Resolve Simple") { applyConflictBatch(.resolveSimple) }
                        .help("Resolve all conflict blocks whose two sides are identical")
                        .disabled(saving || bridge.blocks.isEmpty)
                    Button("Apply Ours Non-conflicts") {
                        applyConflictBatch(.applyOursNonConflicting)
                    }
                        .help("Apply only non-conflicting changes from the local side")
                        .disabled(saving || bridge.blocks.isEmpty)
                    Button("Apply Theirs Non-conflicts") {
                        applyConflictBatch(.applyTheirsNonConflicting)
                    }
                        .help("Apply only non-conflicting changes from the remote side")
                        .disabled(saving || bridge.blocks.isEmpty)
                    Button("↑") { navigateBlock(-1) }
                        .help("Previous Conflict Block")
                        .disabled(bridge.blocks.isEmpty)
                    Text(bridge.blocks.isEmpty ? "No conflict blocks" : "Block \(selectedBlock + 1)/\(bridge.blocks.count)")
                        .font(.caption).foregroundStyle(.secondary).frame(minWidth: 90)
                    Button("↓") { navigateBlock(1) }
                        .help("Next Conflict Block")
                        .disabled(bridge.blocks.isEmpty)
                }
                .padding(6)
            }
            if let preview = conflictBatchPreview,
               preview.simpleBlocks + preview.oursOnlyBlocks + preview.theirsOnlyBlocks + preview.trueConflictBlocks > 0 {
                Text("Safe blocks: \(preview.simpleBlocks) simple · \(preview.oursOnlyBlocks) local-only · \(preview.theirsOnlyBlocks) remote-only · \(preview.trueConflictBlocks) overlapping")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            if !bridge.blocks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(bridge.blocks) { b in
                            blockChip(b)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
            if let feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedbackIsSuccess ? .green : .red)
                    .padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
    }

    var applyPatchToolbar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Keep All Local") { acceptAllBlocks(.ours) }
                    Button("Apply All Patch") { acceptAllBlocks(.theirs) }
                    Button("Apply Non-Conflicts") { applyNonConflictingPatchHunks() }
                        .disabled(patchHunks.allSatisfy { $0.resolution.isResolved || $0.resolution == .notApplied })
                    Button("Apply Selected Changes") { applySelectedPatchHunk() }
                        .help("Apply the patch changes selected in the result or Patch editor to the result editor")
                        .disabled(!canApplySelectedPatchHunk || saving)
                    Button("Ignore Selected Changes") { ignoreSelectedPatchHunk() }
                        .help("Ignore the selected patch hunks and keep the current result")
                        .disabled(!canIgnoreSelectedPatchHunk || saving)
                    Button("Previous Unresolved") { navigatePatchHunk(-1) }
                        .help("Go to the Previous Unresolved Patch Hunk")
                        .disabled(unresolvedPatchHunks.isEmpty)
                    Text(patchHunkSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 180)
                    Button("Next Unresolved") { navigatePatchHunk(1) }
                        .help("Go to the Next Unresolved Patch Hunk")
                        .disabled(unresolvedPatchHunks.isEmpty)
                }
                .padding(6)
            }
            if patchHunks.isEmpty {
                Text("No structured text hunks for this patch file; use the result editor or file-level actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(patchHunks) { hunk in
                            patchHunkChip(hunk)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            if let feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedbackIsSuccess ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    func patchHunkChip(_ hunk: ApplyPatchConflictHunk) -> some View {
        let isSelected = hunk.id == selectedPatchHunkID
        return Button {
            selectedPatchHunkID = hunk.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hunk \(hunk.index + 1)")
                    .font(.caption2.weight(.semibold))
                Text(hunk.resolution.title)
                    .font(.caption2)
                    .foregroundStyle(patchHunkColor(hunk.resolution))
            }
            .padding(5)
            .frame(minWidth: 92, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .help(hunk.header)
    }

    func blockChip(_ b: SwiftConflictBlock) -> some View {
        let isSel = b.index == selectedBlock
        return HStack(spacing: 4) {
            Button {
                selectedBlock = b.index
            } label: {
                Text(isPatchMode ? "Patch Block \(b.index + 1)" : "Block \(b.index + 1)").font(.caption2)
            }
            .buttonStyle(.plain)
            Button("Ours") { resolveBlock(b.index, .ours) }
                .help(oursSideTitle)
            Button(isPatchMode ? "Apply Patch" : "Theirs") { resolveBlock(b.index, .theirs) }
                .help(theirsSideTitle)
            Button("Both") { resolveBlock(b.index, .both) }
        }
        .padding(4)
        .background(isSel ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    func navigateBlock(_ dir: Int) {
        let n = bridge.blocks.count
        guard n > 0 else { return }
        selectedBlock = (selectedBlock + dir + n) % n
    }

    func acceptAllBlocks(_ side: AcceptSide) {
        let count = bridge.blocks.count
        guard isPatchMode || count > 0 else { return }
        if isPatchMode {
            guard !patchHunks.isEmpty else {
                bridge.acceptAll(side)
                feedbackIsSuccess = true
                feedback = side == .ours ? "Kept all local results" : "Applied all patch hunks"
                return
            }
            var resolved = 0
            for hunk in patchHunks.reversed() {
                guard !hunk.resolution.isResolved else { continue }
                if side == .ours {
                    _ = bridge.ignorePatchHunk(hunk)
                    setPatchHunkResolution(hunk.id, .ignored)
                    resolved += 1
                } else {
                    switch bridge.applyPatchHunk(hunk) {
                    case .applied:
                        setPatchHunkResolution(hunk.id, .applied)
                        resolved += 1
                    case .alreadyApplied:
                        setPatchHunkResolution(hunk.id, .automaticallyApplied)
                        resolved += 1
                    case .pending, .notApplied, .automaticallyApplied, .ignored:
                        break
                    }
                }
            }
            refreshUnresolvedPatchHunks()
            selectedPatchHunkID = nil
            feedbackIsSuccess = resolved > 0
            feedback = side == .ours
                ? "Ignored \(resolved) patch hunk(s)"
                : "Applied \(resolved) patch hunk(s)"
            return
        }
        bridge.acceptAll(side)
        feedbackIsSuccess = true
        feedback = side == .ours ? "All local conflicts accepted" : "All remote conflicts accepted"
    }

    func applyConflictBatch(_ action: ConflictBatchAction) {
        guard let repo, !saving else { return }
        let path = self.path
        let repositoryID = repo.gitDir()
        let resultContent = bridge.getResultText()
        bridge.setResultEditingEnabled(false)
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.conflictApplyBatch(
                    path: path,
                    resultContent: resultContent,
                    action: action
                )
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else {
                        self.onChanged()
                        return
                    }
                    self.feedbackIsSuccess = result.fullyResolved
                    self.feedback = result.fullyResolved
                        ? "All eligible conflicts resolved"
                        : "Applied \(result.appliedBlocks) safe block(s); \(result.remainingBlocks) remain"
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else { return }
                    self.feedbackIsSuccess = false
                    self.feedback = "\(error)"
                }
            }
        }
    }

    func resolveBlock(_ index: Int, _ side: AcceptSide) {
        guard bridge.blocks.contains(where: { $0.index == index }) else { return }
        bridge.acceptBlock(index, side)
        if selectedBlock >= bridge.blocks.count {
            selectedBlock = max(0, bridge.blocks.count - 1)
        }
    }

    var patchHunkSummary: String {
        guard !patchHunks.isEmpty else { return "No patch hunks" }
        let resolved = patchHunks.filter { $0.resolution.isResolved }.count
        if resolved == patchHunks.count {
            return "All patch hunks resolved"
        }
        let selected = selectedPatchHunk.map { "Hunk \($0.index + 1) · " } ?? ""
        return "\(selected)\(resolved)/\(patchHunks.count) resolved"
    }

    var canApplySelectedPatchHunk: Bool {
        actionPatchHunks.contains { hunk in
            !hunk.resolution.isResolved
                && (hunk.resolution == .pending || bridge.canApplyPatchHunk(hunk))
        }
    }

    var canIgnoreSelectedPatchHunk: Bool {
        actionPatchHunks.contains { !$0.resolution.isResolved }
    }

    func patchHunkColor(_ resolution: ApplyPatchHunkResolution) -> Color {
        switch resolution {
        case .pending: return .orange
        case .alreadyApplied, .automaticallyApplied: return .green
        case .notApplied: return .red
        case .applied: return .green
        case .ignored: return .secondary
        }
    }

    func navigatePatchHunk(_ direction: Int) {
        let candidates = unresolvedPatchHunks
        guard !candidates.isEmpty else { return }
        let currentIndex = selectedPatchHunk.flatMap { hunk in
            candidates.firstIndex { $0.id == hunk.id }
        } ?? (direction > 0 ? -1 : 0)
        let next = (currentIndex + direction + candidates.count) % candidates.count
        selectedPatchHunkID = candidates[next].id
    }

    func applySelectedPatchHunk(_ explicitHunk: ApplyPatchConflictHunk? = nil) {
        let candidates = (explicitHunk.map { [$0] } ?? actionPatchHunks)
            .filter { !$0.resolution.isResolved }
        guard !candidates.isEmpty else { return }

        var applied = 0
        var alreadyApplied = 0
        var skipped = 0
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Apply Selected Changes")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        // Apply from the bottom up so a replacement cannot invalidate the
        // editor ranges used by a later selected change.
        for hunk in candidates.reversed() {
            selectedPatchHunkID = hunk.id
            switch bridge.applyPatchHunk(hunk) {
            case .applied:
                setPatchHunkResolution(hunk.id, .applied)
                applied += 1
            case .alreadyApplied:
                setPatchHunkResolution(hunk.id, .automaticallyApplied)
                alreadyApplied += 1
            case .notApplied, .pending, .automaticallyApplied, .ignored:
                skipped += 1
            }
        }
        refreshUnresolvedPatchHunks()
        feedbackIsSuccess = skipped == 0
        feedback = "Applied \(applied + alreadyApplied) patch change(s)"
            + (skipped == 0 ? "" : "; skipped \(skipped) change(s) that could not be applied exactly")
        selectNextUnresolvedPatchHunkIfNeeded()
    }

    func ignoreSelectedPatchHunk(_ explicitHunk: ApplyPatchConflictHunk? = nil) {
        let candidates = (explicitHunk.map { [$0] } ?? actionPatchHunks)
            .filter { !$0.resolution.isResolved }
        guard !candidates.isEmpty else { return }
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Ignore Selected Changes")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        for hunk in candidates {
            selectedPatchHunkID = hunk.id
            _ = bridge.ignorePatchHunk(hunk)
            setPatchHunkResolution(hunk.id, .ignored)
        }
        refreshUnresolvedPatchHunks()
        feedbackIsSuccess = true
        feedback = "Ignored \(candidates.count) patch change(s)"
        selectNextUnresolvedPatchHunkIfNeeded()
    }

    func copyPatchHunk(_ hunk: ApplyPatchConflictHunk) {
        guard let content = ApplyPatchConflictHunkModel.clipboardText(for: hunk) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        selectedPatchHunkID = hunk.id
        feedbackIsSuccess = true
        feedback = "Copied patch content for Hunk \(hunk.index + 1)"
    }

    func applyNonConflictingPatchHunks() {
        var appliedCount = 0
        var automaticallyResolvedCount = 0
        let candidates = patchHunks.filter { !$0.resolution.isResolved }
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Apply Non-Conflicts")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        for hunk in candidates.reversed() {
            guard !hunk.resolution.isResolved else { continue }
            if hunk.resolution == .alreadyApplied {
                setPatchHunkResolution(hunk.id, .automaticallyApplied)
                automaticallyResolvedCount += 1
                continue
            }
            guard hunk.resolution == .pending || bridge.canApplyPatchHunk(hunk) else { continue }
            if bridge.applyPatchHunk(hunk) == .applied {
                setPatchHunkResolution(hunk.id, .applied)
                appliedCount += 1
            }
        }
        refreshUnresolvedPatchHunks()
        selectNextUnresolvedPatchHunkIfNeeded()
        let total = appliedCount + automaticallyResolvedCount
        feedbackIsSuccess = total > 0
        feedback = total == 0
            ? "No patch hunks could be applied automatically"
            : "Processed \(total) patch hunk(s) automatically"
    }

    func setPatchHunkResolution(
        _ id: String,
        _ resolution: ApplyPatchHunkResolution
    ) {
        guard let index = patchHunks.firstIndex(where: { $0.id == id }) else { return }
        if persistPatchHunkResolution(patchHunks[index], resolution) {
            patchHunks[index].resolution = resolution
        }
    }

    func persistPatchHunkResolution(
        _ hunk: ApplyPatchConflictHunk,
        _ resolution: ApplyPatchHunkResolution
    ) -> Bool {
        guard isPatchMode, let repo, let restoreName else { return true }
        let rawResolution: String
        switch resolution {
        case .applied: rawResolution = "applied"
        case .automaticallyApplied: rawResolution = "automatically_applied"
        case .ignored: rawResolution = "ignored"
        case .pending, .alreadyApplied, .notApplied: return true
        }
        do {
            try repo.shelveSetRestoreHunkResolution(
                name: restoreName,
                path: hunk.path,
                hunkIndex: hunk.index,
                resolution: rawResolution
            )
        } catch {
            feedbackIsSuccess = false
            feedback = "Failed to save patch hunk state: \(error)"
            return false
        }
        return true
    }

    func selectNextUnresolvedPatchHunkIfNeeded() {
        guard selectedPatchHunk?.resolution.isResolved == true else { return }
        selectedPatchHunkID = patchHunks.first(where: { !$0.resolution.isResolved })?.id
    }

    func refreshUnresolvedPatchHunks() {
        guard isPatchMode else { return }
        let result = bridge.getResultText()
        patchHunks = patchHunks.map { hunk in
            var updated = hunk
            if !updated.resolution.isResolved {
                updated.resolution = ApplyPatchConflictHunkModel.status(of: updated, in: result)
            }
            return updated
        }
        if selectedPatchHunkID == nil {
            selectedPatchHunkID = patchHunks.first(where: { !$0.resolution.isResolved })?.id
        }
    }

    var baseSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Base (common ancestor)").font(.headline)
                Spacer()
                Button("Close") { showBase = false }
            }.padding(10)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(conflict?.base ?? "None")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    var patchPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Patch to Apply").font(.headline)
                Spacer()
                Button("Close") { showPatchPreview = false }
            }
            .padding(10)
            Divider()
            if let patchPreviewDiff, !patchPreviewDiff.binary, !patchPreviewDiff.hunks.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Structured patch preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Diff View", selection: $patchPreviewPresentationMode) {
                            ForEach(DiffPresentationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Design.Colors.surface)
                    if patchPreviewPresentationMode == .sideBySide {
                        SideBySideDiffView(fileDiff: patchPreviewDiff)
                    } else {
                        UnifiedDiffView(fileDiff: patchPreviewDiff)
                    }
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(patchText ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    var localDiffSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local → Result").font(.headline)
                Spacer()
                Button("Close") { showLocalDiff = false }
            }
            .padding(10)
            Divider()
            if localDiffLoading {
                ProgressView("Loading local diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let localDiff {
                if localDiff.binary {
                    Label("Binary content cannot be rendered as a text diff.", systemImage: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                        .padding(16)
                    Spacer()
                } else if localDiff.hunks.isEmpty {
                    Text("No changes between local and the current result.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text(path)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Picker("Diff View", selection: $localDiffPresentationMode) {
                                ForEach(DiffPresentationMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Design.Colors.surface)
                        if localDiffPresentationMode == .sideBySide {
                            SideBySideDiffView(fileDiff: localDiff)
                        } else {
                            UnifiedDiffView(fileDiff: localDiff)
                        }
                    }
                }
            } else if let localDiffError {
                Text(localDiffError)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(16)
                Spacer()
            } else {
                Text("No local diff loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    func loadLocalDiff() {
        guard isPatchMode, let repo, let conflict else { return }
        let path = self.path
        let local = conflict.ours
        let result = bridge.getResultText()
        localDiff = nil
        localDiffError = nil
        localDiffLoading = true
        showLocalDiff = true
        Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.diffTexts(
                    path: path,
                    oldText: local,
                    newText: result,
                    ignoreWhitespace: false
                )
                await MainActor.run {
                    self.localDiff = diff
                    self.localDiffLoading = false
                }
            } catch {
                await MainActor.run {
                    self.localDiffError = "Could not build the local diff: \(error)"
                    self.localDiffLoading = false
                }
            }
        }
    }

    func load() {
        loadGeneration &+= 1
        let generation = loadGeneration
        conflict = nil
        conflictIsBinary = false
        conflictBatchPreview = nil
        conflictError = nil
        patchHunks = []
        selectedPatchHunkID = nil
        guard let repo else { return }
        let path = self.path
        let repositoryID = repo.gitDir()
        let directPatchText = patchText
        let restoreName = self.restoreName
        Task.detached(priority: .userInitiated) {
            do {
                let workspace = try repo.conflictWorkspace()
                let persistedResolutions: [ShelveRestoreHunkResolution]
                if directPatchText != nil, let restoreName,
                   let restoreInfo = try? repo.shelveRestoreInfo(),
                   restoreInfo.name == restoreName {
                    persistedResolutions = restoreInfo.resolvedHunks
                } else {
                    persistedResolutions = []
                }
                guard let workspaceFile = workspace.files.first(where: { $0.path == path }) else {
                    await MainActor.run {
                        guard isCurrentConflictLoadRequest(
                            repositoryID: repositoryID,
                            path: path,
                            generation: generation,
                            currentRepositoryID: self.repo?.gitDir(),
                            currentPath: self.path,
                            currentGeneration: self.loadGeneration
                        ) else { return }
                        self.conflict = nil
                        self.conflictIsBinary = false
                        self.conflictBatchPreview = nil
                        self.conflictError = "The conflict file is resolved or no longer exists: \(path)"
                        self.patchHunks = []
                        self.selectedPatchHunkID = nil
                    }
                    return
                }
                let cf = workspaceFile.file
                let operationKind = workspace.operation
                let mergeSourceReference = repo.mergeSourceReference()
                let batchPreview = directPatchText == nil
                    ? try? repo.conflictBatchPreview(path: path)
                    : nil
                await MainActor.run {
                    guard isCurrentConflictLoadRequest(
                        repositoryID: repositoryID,
                        path: path,
                        generation: generation,
                        currentRepositoryID: self.repo?.gitDir(),
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    var restoredHunks = directPatchText.map {
                        ApplyPatchConflictHunkModel.parse(
                            patch: $0,
                            path: path,
                            result: cf.result
                        )
                    } ?? []
                    for index in restoredHunks.indices {
                        if let resolution = ApplyPatchConflictHunkModel.restoredResolution(
                            for: restoredHunks[index],
                            from: persistedResolutions
                        ) {
                            restoredHunks[index].resolution = resolution
                        }
                    }
                    self.conflict = cf
                    self.conflictIsBinary = workspaceFile.binary
                    self.operationKind = operationKind
                    self.mergeSourceReference = mergeSourceReference
                    self.conflictBatchPreview = batchPreview
                    self.conflictError = nil
                    self.selectedBlock = 0
                    self.patchHunks = restoredHunks
                    self.selectedPatchHunkID = self.patchHunks
                        .first(where: { !$0.resolution.isResolved })?.id
                        ?? self.patchHunks.first?.id
                    self.reloadToken += 1  // 外部重载：触发编辑器同步
                }
            } catch {
                await MainActor.run {
                    guard isCurrentConflictLoadRequest(
                        repositoryID: repositoryID,
                        path: path,
                        generation: generation,
                        currentRepositoryID: self.repo?.gitDir(),
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.conflict = nil
                    self.conflictIsBinary = false
                    self.conflictBatchPreview = nil
                    self.conflictError = "\(error)"
                    self.patchHunks = []
                    self.selectedPatchHunkID = nil
                }
            }
        }
    }

    /// 标记已解决：取结果栏文本 -> resolve_edited -> 刷新 status（文件不再显示 !）。
    /// 文件级 Accept（CONFLICT-001）：整文件接受一侧或双方，二进制安全。
    func acceptFile(_ pick: FilePick) {
        guard let repo, !saving else { return }
        let path = self.path
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.acceptConflict(path: path, pick: pick)
                await MainActor.run {
                    self.saving = false
                    self.feedbackIsSuccess = true
                    self.feedback = pick == .both
                        ? "Accepted both sides"
                        : pick == .ours
                            ? "Accepted the local side"
                            : (self.isPatchMode ? "Applied the patch side" : "Accepted the remote side")
                    self.onChanged()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.conflictError = "\(error)"
                }
            }
        }
    }

    /// 重置冲突现场：放弃当前编辑，从 index stages 重新生成 marker。
    func resetConflictFile() {
        guard let repo, !saving else { return }
        let path = self.path
        let restoreName = self.restoreName
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.resetConflict(path: path)
                let resetFeedback: String
                let resetSucceeded: Bool
                if let restoreName {
                    do {
                        try repo.shelveClearRestoreHunkResolutions(name: restoreName, path: path)
                        resetFeedback = "Reset to unresolved"
                        resetSucceeded = true
                    } catch {
                        resetFeedback = "Reset to unresolved, but clearing the recovery state failed: \(error)"
                        resetSucceeded = false
                    }
                } else {
                    resetFeedback = "Reset to unresolved"
                    resetSucceeded = true
                }
                await MainActor.run {
                    self.saving = false
                    self.feedbackIsSuccess = resetSucceeded
                    self.feedback = resetFeedback
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.conflictError = "\(error)"
                }
            }
        }
    }

    func markResolved() {
        guard repo != nil, !saving else { return }
        let content = bridge.getResultText()
        if isPatchMode {
            // textDidChange coalesces through the main queue; refresh once
            // synchronously here so a fast click after editing cannot bypass
            // the partial-resolution confirmation with stale hunk state.
            refreshUnresolvedPatchHunks()
        }
        if isPatchMode, !unresolvedPatchHunks.isEmpty {
            pendingResolveContent = content
            showPartialResolveConfirmation = true
            return
        }
        if !parseConflictMarkers(content).isEmpty {
            feedbackIsSuccess = false
            feedback = "There are still unresolved conflict markers; resolve every conflict block first"
            return
        }
        resolveEditedContent(content)
    }

    func resolveEditedContent(
        _ content: String,
        allowConflictMarkers: Bool = false
    ) {
        guard let repo, !saving else { return }
        let path = self.path
        let repositoryID = repo.gitDir()
        bridge.setResultEditingEnabled(false)
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                if allowConflictMarkers {
                    try repo.resolveEditedAllowConflictMarkers(path: path, content: content)
                } else {
                    try repo.resolveEdited(path: path, content: content)
                }
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else {
                        self.onChanged()
                        return
                    }
                    self.feedbackIsSuccess = true
                    self.feedback = "Marked as resolved"
                    self.onChanged()
                }
            } catch {
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else { return }
                    self.feedbackIsSuccess = false
                    self.feedback = "\(error)"
                }
            }
        }
    }

    /// 运行 Git 配置的 mergetool；Git 返回后重新读取 index stages，保留
    /// 外部工具只改工作区但未完成 stage 的情况，不能把它误报成已解决。
    func openExternalTool() {
        guard let repo, !externalToolWorking else { return }
        let path = self.path
        let cancelHandle = GitCancelHandle()
        externalToolWorking = true
        externalToolCancelling = false
        externalToolCancelHandle = cancelHandle
        conflictError = nil
        feedback = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.openExternalMergeToolWithCancel(path: path, cancel: cancelHandle)
                await MainActor.run {
                    self.externalToolWorking = false
                    self.externalToolCancelling = false
                    self.externalToolCancelHandle = nil
                    self.onChanged()
                    if result.resolved {
                        self.conflict = nil
                        self.conflictIsBinary = false
                        self.feedback = "External merge tool resolved the file."
                    } else {
                        self.feedback = "External merge tool returned; conflicts remain."
                        self.load()
                    }
                }
            } catch {
                await MainActor.run {
                    self.externalToolWorking = false
                    self.externalToolCancelling = false
                    self.externalToolCancelHandle = nil
                    if cancelHandle.isCancelled() {
                        self.feedback = String(localized: "External merge tool canceled.")
                        self.load()
                    } else {
                        self.conflictError = "\(error)"
                    }
                }
            }
        }
    }
}
