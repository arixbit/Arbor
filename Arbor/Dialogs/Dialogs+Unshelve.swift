import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedUnshelveDialog: View {
    let name: String
    let paths: [String]
    let initialPaths: [String]
    let changeLists: [ChangeListInfo]
    let repo: Repository?
    var patchText: String? = nil
    @Binding var removeAppliedFilesFromShelf: Bool
    let onUnshelve: ([String], [ShelvePatchSelection], String?, Bool, String?, UInt32, String?) -> Void
    var onApplyPatch: ([String], [ShelvePatchSelection], String?, String?, UInt32) -> Void = { _, _, _, _, _ in }
    let onCancel: () -> Void
    @State private var selectedPaths: Set<String> = []
    @State private var selectedHunkIDs: Set<String> = []
    @State private var patchFiles: [RebasedShelfPatchFile] = []
    @State private var loadedPatchText = ""
    @State private var patchLoadError: String?
    @State private var isLoadingPatch = false
    @State private var previewPath: String?
    @State private var previewDiff: FileDiff?
    @State private var previewError: String?
    @State private var isLoadingPreview = false
    @State private var previewGeneration = 0
    @State private var previewPresentationMode: DiffPresentationMode = .sideBySide
    @State private var groupByDirectory = true
    @State private var collapsedPatchFolders: Set<String> = []
    @State private var targetName = ""
    @State private var changelistComment = ""
    @State private var isImportedShelf = false
    @State private var mappedBaseDirectory: String?
    @State private var mappedPathStrip: UInt32 = 1
    @State private var defaultPathStrip: UInt32 = 1
    @State private var baseDirectoryError: String?
    @State private var suggestedBaseMappings: [RebasedPatchBaseCandidate] = []

    private var selectedPathCount: Int {
        selectedPaths.intersection(paths).count
    }

    private var selectedHunkCount: Int {
        selectedHunkIDs.count
    }

    private var selectedFilesAreApplicable: Bool {
        guard isImportedShelf else { return true }
        guard !patchFiles.isEmpty else { return true }
        let selectedFiles = patchFiles.filter { selectedPaths.contains($0.path) }
        return !selectedFiles.isEmpty && selectedFiles.allSatisfy {
            patchApplicabilityIssue(for: $0) == nil
        }
    }

    private var selectedPatchSelections: [ShelvePatchSelection] {
        guard !patchFiles.isEmpty else { return [] }
        let validPaths = Set(paths)
        return patchFiles
            .filter { validPaths.contains($0.path) }
            .flatMap { file -> [ShelvePatchSelection] in
                guard selectedPaths.contains(file.path) else { return [] }
                if file.isWholeFileOnly {
                    return [ShelvePatchSelection(path: file.path, hunkIndex: nil)]
                }
                return file.hunks.compactMap { hunk in
                    selectedHunkIDs.contains(hunk.id)
                        ? ShelvePatchSelection(path: file.path, hunkIndex: hunk.index)
                        : nil
                }
            }
    }

    private var visiblePatchRows: [ShelfTreeRow] {
        let rows = shelfTreeRows(
            paths: patchFiles.map(\.path),
            groupByDirectory: groupByDirectory
        )
        guard groupByDirectory else { return rows }
        return rows.filter { row in
            !rows.contains { folder in
                folder.isFolder
                    && row.path.hasPrefix(folder.path + "/")
                    && collapsedPatchFolders.contains(folder.path)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(patchText == nil ? "Unshelve" : "Apply Patch")
                .font(.title3.weight(.semibold))
            Text(patchText == nil
                ? "Apply selected changes from this Shelf to the working tree."
                : "Review and apply the selected patch changes to the working tree.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text("Files selected: \(selectedPathCount)/\(paths.count)")
                if selectedHunkCount > 0 {
                    Text("· \(selectedHunkCount) hunks")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Select All") { selectAll() }
                Button("Clear") { clearSelection() }
                if isLoadingPatch {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            if let patchLoadError {
                Text(patchLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if paths.isEmpty {
                Text("No patch files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if patchFiles.isEmpty || isLoadingPatch {
                fileSelectionFallback
            } else {
                HSplitView {
                    patchSelectionList
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: 460)
                    patchPreview
                        .frame(minWidth: 360)
                }
                .frame(height: CGFloat(min(480, max(240, (paths.count + selectedHunkCount) * 30))))
            }
            if isImportedShelf {
                patchBaseDirectoryPanel
            }
            Picker("Target Changelist", selection: $targetName) {
                Text("Default / automatic").tag("")
                ForEach(changeLists, id: \.name) { list in
                    Text(list.name).tag(list.name)
                }
            }
            .pickerStyle(.menu)
            if patchText == nil {
                TextField("Changelist comment (optional)", text: $changelistComment)
                    .textFieldStyle(.roundedBorder)
            }
            if patchText == nil {
                Toggle("Remove Applied Files from Shelf", isOn: $removeAppliedFilesFromShelf)
                    .toggleStyle(.checkbox)
                if removeAppliedFilesFromShelf {
                    Text("Applied files will be moved to Recently Deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(patchText == nil ? "Unshelve" : "Apply Patch", action: {
                    let selected = paths.filter { selectedPaths.contains($0) }
                    if patchText == nil {
                        onUnshelve(
                            selected,
                            selectedPatchSelections,
                            targetName.isEmpty ? nil : targetName,
                            removeAppliedFilesFromShelf,
                            mappedBaseDirectory,
                            mappedPathStrip,
                            changelistComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : changelistComment.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    } else {
                        onApplyPatch(
                            selected,
                            selectedPatchSelections,
                            targetName.isEmpty ? nil : targetName,
                            mappedBaseDirectory,
                            mappedPathStrip
                        )
                    }
                })
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        selectedPathCount == 0
                            || isLoadingPatch
                            || !selectedFilesAreApplicable
                    )
            }
        }
        .padding(20)
        .frame(width: 980, height: isImportedShelf ? 800 : 720)
        .onAppear {
            selectedPaths = Set(initialPaths.filter(Set(paths).contains))
            targetName = ""
            mappedBaseDirectory = nil
            mappedPathStrip = 1
            defaultPathStrip = 1
            baseDirectoryError = nil
            isImportedShelf = false
            suggestedBaseMappings = []
            loadedPatchText = ""
            previewGeneration = 0
            loadPatch()
        }
        .onChange(of: mappedBaseDirectory) { _, _ in
            guard isImportedShelf else { return }
            loadPreview(previewPath)
        }
        .onChange(of: mappedPathStrip) { _, _ in
            guard isImportedShelf else { return }
            loadPreview(previewPath)
        }
    }

    @ViewBuilder
    private var patchSelectionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    groupByDirectory.toggle()
                    if !groupByDirectory { collapsedPatchFolders.removeAll() }
                } label: {
                    Label(
                        groupByDirectory ? "Flatten Directories" : "Group by Directory",
                        systemImage: groupByDirectory ? "rectangle.split.3x1" : "folder"
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                patchStatusLegend
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Design.Colors.surface)

            List {
                ForEach(visiblePatchRows) { row in
                    if row.isFolder {
                        Button {
                            if collapsedPatchFolders.contains(row.path) {
                                collapsedPatchFolders.remove(row.path)
                            } else {
                                collapsedPatchFolders.insert(row.path)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: collapsedPatchFolders.contains(row.path)
                                    ? "chevron.right"
                                    : "chevron.down")
                                    .font(.caption2.weight(.bold))
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(row.depth * 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else if let file = patchFiles.first(where: { $0.path == row.path }) {
                        patchFileRow(file, depth: row.depth)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var patchStatusLegend: some View {
        HStack(spacing: 6) {
            ForEach(RebasedShelfPatchStatus.allCases) { status in
                let count = patchFiles.filter { $0.status == status }.count
                if count > 0 {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                        Text("\(count)")
                        Text(LocalizedStringKey(status.rawValue))
                    }
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func patchFileRow(_ file: RebasedShelfPatchFile, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { isFileSelected(file) },
                    set: { setFileSelected(file, isSelected: $0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: file.isBinary ? "doc.fill" : "doc.text")
                            .foregroundStyle(.secondary)
                        Text(groupByDirectory
                            ? (file.path.split(separator: "/").last.map(String.init) ?? file.path)
                            : file.path)
                            .lineLimit(1)
                        Text(LocalizedStringKey(file.status.rawValue))
                            .font(.caption2)
                            .foregroundStyle(file.status.color)
                        if file.isBinary {
                            Text("Binary")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let issue = patchApplicabilityIssue(for: file) {
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(patchApplicabilityIssue(for: file) != nil)
                Button {
                    loadPreview(file.path)
                } label: {
                    Image(systemName: previewPath == file.path ? "eye.fill" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(previewPath == file.path ? Color.accentColor : Color.secondary)
                .help("Preview file diff")
            }
            .padding(.leading, CGFloat(depth * 14))
            if !file.isWholeFileOnly {
                ForEach(file.hunks) { hunk in
                    Toggle(isOn: Binding(
                        get: { selectedHunkIDs.contains(hunk.id) },
                        set: { setHunkSelected(hunk, isSelected: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hunk.header)
                                .font(.system(size: 11, design: .monospaced))
                            if !hunk.preview.isEmpty {
                                Text(hunk.preview)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { loadPreview(file.path) }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, CGFloat(depth * 14 + 22))
                    .disabled(patchApplicabilityIssue(for: file) != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var patchPreview: some View {
        if let previewPath,
           let file = patchFiles.first(where: { $0.path == previewPath }) {
            if isLoadingPreview {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let previewDiff {
                if previewDiff.binary {
                    rawPatchView(file.rawPatch)
                } else if previewDiff.hunks.isEmpty {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text(isImportedShelf ? "Local → Applied Patch · \(file.path)" : file.path)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Picker("Diff View", selection: $previewPresentationMode) {
                                ForEach(DiffPresentationMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Design.Colors.surface)
                        if previewPresentationMode == .sideBySide {
                            SideBySideDiffView(fileDiff: previewDiff)
                        } else {
                            UnifiedDiffView(fileDiff: previewDiff)
                        }
                    }
                }
            } else if let previewError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Structured diff unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(previewError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    rawPatchView(file.rawPatch)
                }
                .padding(8)
            } else {
                rawPatchView(file.rawPatch)
            }
        } else {
            Text("Select a file to preview its diff")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rawPatchView(_ patch: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(patch.isEmpty ? "No patch details" : patch)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
    }

    private var fileSelectionFallback: some View {
        List(paths, id: \.self) { path in
            Toggle(isOn: Binding(
                get: { selectedPaths.contains(path) },
                set: { selected in
                    if selected { selectedPaths.insert(path) }
                    else { selectedPaths.remove(path) }
                }
            )) {
                Text(path).lineLimit(1)
            }
            .toggleStyle(.checkbox)
        }
        .frame(height: CGFloat(min(260, max(80, paths.count * 24))))
    }

    private var patchBaseDirectoryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Patch Base Directory", systemImage: "folder.badge.gearshape")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(mappedBaseDirectory ?? "Repository root") · −p\(mappedPathStrip)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Map Base Directory…", action: choosePatchBaseDirectory)
                if mappedBaseDirectory != nil {
                    Button("Use Repository Root") {
                        mappedBaseDirectory = nil
                        mappedPathStrip = defaultPathStrip
                        baseDirectoryError = nil
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Imported patches are applied relative to this directory.")
                Spacer()
                Stepper(value: $mappedPathStrip, in: UInt32(0)...UInt32(16)) {
                    Text("Path strip −p\(mappedPathStrip)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let baseDirectoryError {
                Text(baseDirectoryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !suggestedBaseMappings.isEmpty {
                HStack(spacing: 6) {
                    Text("Suggested bases:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu("Choose Suggested Base") {
                        ForEach(suggestedBaseMappings) { candidate in
                            Button(candidate.title) {
                                mappedBaseDirectory = candidate.basePath.isEmpty ? nil : candidate.basePath
                                mappedPathStrip = candidate.pathStrip
                                baseDirectoryError = nil
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(8)
        .background(Design.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func choosePatchBaseDirectory() {
        guard let repositoryRoot = repositoryRootURL else {
            baseDirectoryError = "Repository working directory is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = repositoryRoot
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let root = repositoryRoot.resolvingSymlinksInPath()
        let selected = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard selected.path == root.path || selected.path.hasPrefix(root.path + "/") else {
            baseDirectoryError = "Selected base directory must be inside the repository."
            return
        }
        baseDirectoryError = nil
        if selected.path == root.path {
            mappedBaseDirectory = nil
        } else {
            mappedBaseDirectory = String(selected.path.dropFirst(root.path.count + 1))
        }
    }

    private var repositoryRootURL: URL? {
        guard let workdir = repo?.workdir(), !workdir.isEmpty else { return nil }
        return URL(fileURLWithPath: workdir).standardizedFileURL
    }

    private func selectAll() {
        guard !isImportedShelf || !patchFiles.isEmpty else {
            selectedPaths = Set(paths)
            selectedHunkIDs.removeAll()
            return
        }
        let selectableFiles = patchFiles.filter { patchApplicabilityIssue(for: $0) == nil }
        selectedPaths = isImportedShelf ? Set(selectableFiles.map(\.path)) : Set(paths)
        selectedHunkIDs = Set(selectableFiles.flatMap { $0.hunks.map(\.id) })
    }

    private func clearSelection() {
        selectedPaths.removeAll()
        selectedHunkIDs.removeAll()
    }

    private func isFileSelected(_ file: RebasedShelfPatchFile) -> Bool {
        guard selectedPaths.contains(file.path) else { return false }
        return file.isWholeFileOnly || file.hunks.allSatisfy { selectedHunkIDs.contains($0.id) }
    }

    private func setFileSelected(_ file: RebasedShelfPatchFile, isSelected: Bool) {
        if isSelected {
            selectedPaths.insert(file.path)
            selectedHunkIDs.formUnion(file.hunks.map(\.id))
        } else {
            selectedPaths.remove(file.path)
            selectedHunkIDs.subtract(file.hunks.map(\.id))
        }
    }

    private func setHunkSelected(_ hunk: RebasedShelfPatchHunk, isSelected: Bool) {
        if isSelected {
            selectedHunkIDs.insert(hunk.id)
            selectedPaths.insert(hunk.path)
        } else {
            selectedHunkIDs.remove(hunk.id)
            let hasSelectedHunk = patchFiles
                .first(where: { $0.path == hunk.path })?.hunks
                .contains(where: { selectedHunkIDs.contains($0.id) }) ?? false
            if !hasSelectedHunk { selectedPaths.remove(hunk.path) }
        }
    }

    private func loadPatch() {
        guard let repo else { return }
        isLoadingPatch = true
        patchLoadError = nil
        let rootPath = repositoryRootURL?.path
        let suppliedPatch = patchText
        Task.detached(priority: .userInitiated) {
            do {
                let imported = suppliedPatch != nil
                    || ((try? repo.shelveIsImported(name: name)) ?? false)
                let patch: String
                if let suppliedPatch {
                    patch = suppliedPatch
                } else {
                    patch = try repo.shelveDiff(name: name)
                }
                let parsedFiles = Self.parsePatchFiles(patch, allowedPaths: paths)
                let parsedPaths = Set(parsedFiles.map(\.path))
                let files = Set(paths).isSubset(of: parsedPaths) ? parsedFiles : []
                let indexedPaths = (try? repo.patchIndexPaths()) ?? []
                let candidateScope = rootPath.map {
                    RebasedPatchCandidateScope.repository(rootPath: $0)
                }
                let filenameIndex = rootPath.map {
                    RebasedPatchFilenameIndexStore.loadOrBuild(
                        rootPath: $0,
                        indexedPaths: indexedPaths,
                        scope: candidateScope
                    )
                }
                let candidates = Self.discoverBaseMappings(
                    patchFiles: files,
                    rootPath: rootPath,
                    indexedPaths: indexedPaths,
                    scope: candidateScope,
                    filenameIndex: filenameIndex
                )
                let defaultStrip = Self.defaultPathStrip(for: files)
                await MainActor.run {
                    self.isImportedShelf = imported
                    self.loadedPatchText = patch
                    self.patchFiles = files
                    self.suggestedBaseMappings = candidates
                    self.defaultPathStrip = defaultStrip
                    self.mappedPathStrip = defaultStrip
                    // MatchPatchPaths selects a best text/strip variant. For
                    // ambiguous new files it deliberately falls back to the
                    // project root and leaves the suggestion menu available.
                    if imported,
                       let candidate = Self.automaticallySelectedBaseMapping(
                           patchFiles: files,
                           candidates: candidates
                       ) {
                        self.mappedBaseDirectory = candidate.basePath.isEmpty ? nil : candidate.basePath
                        self.mappedPathStrip = candidate.pathStrip
                    }
                    self.isLoadingPatch = false
                    self.previewPath = files.first?.path
                    if files.isEmpty {
                        self.patchLoadError = "Patch details are unavailable; using file selection."
                    } else {
                        self.initializeHunkSelection()
                        self.loadPreview(files.first?.path)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImportedShelf = suppliedPatch != nil
                        || ((try? repo.shelveIsImported(name: name)) ?? false)
                    self.isLoadingPatch = false
                    self.patchLoadError = "Patch details are unavailable; using file selection."
                }
            }
        }
    }

    private func loadPreview(_ path: String?) {
        previewGeneration &+= 1
        let generation = previewGeneration
        guard let path else {
            previewPath = nil
            previewDiff = nil
            previewError = nil
            isLoadingPreview = false
            return
        }
        previewPath = path
        previewDiff = nil
        previewError = nil
        if isImportedShelf {
            guard let repo, !loadedPatchText.isEmpty else {
                isLoadingPreview = false
                return
            }
            isLoadingPreview = true
            let patch = loadedPatchText
            let baseDirectory = mappedBaseDirectory ?? ""
            let pathStrip = mappedPathStrip
            Task.detached(priority: .userInitiated) {
                do {
                    let diff = try repo.importedPatchFileDiff(
                        patch: patch,
                        path: path,
                        baseDirectory: baseDirectory,
                        pathStrip: pathStrip,
                        ignoreWhitespace: false
                    )
                    await MainActor.run {
                        guard self.previewPath == path,
                              self.previewGeneration == generation else { return }
                        self.previewDiff = diff
                        self.previewError = nil
                        self.isLoadingPreview = false
                    }
                } catch {
                    await MainActor.run {
                        guard self.previewPath == path,
                              self.previewGeneration == generation else { return }
                        self.previewDiff = nil
                        self.previewError = String(describing: error)
                        self.isLoadingPreview = false
                    }
                }
            }
            return
        }
        if patchText != nil {
            if let rawPatch = patchFiles.first(where: { $0.path == path })?.rawPatch {
                previewDiff = RebasedPatchDiffParser.parse(patch: rawPatch, path: path)
            }
            isLoadingPreview = false
            return
        }
        guard let repo, patchText == nil else {
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true
        let shelfName = name
        Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.shelveFileDiffWithSettings(
                    name: shelfName,
                    path: path,
                    withLocal: false,
                    settings: makeArborGitDiffSettings()
                )
                await MainActor.run {
                    guard self.previewPath == path,
                          self.previewGeneration == generation else { return }
                    self.previewDiff = diff
                    self.previewError = nil
                    self.isLoadingPreview = false
                }
            } catch {
                await MainActor.run {
                    guard self.previewPath == path,
                          self.previewGeneration == generation else { return }
                    self.previewDiff = nil
                    self.previewError = String(describing: error)
                    self.isLoadingPreview = false
                }
            }
        }
    }

    private func initializeHunkSelection() {
        let initial = Set(initialPaths)
        selectedHunkIDs = Set(
            patchFiles
                .filter { initial.contains($0.path) && patchApplicabilityIssue(for: $0) == nil }
                .flatMap { $0.hunks.map(\.id) }
        )
        selectedPaths = Set(
            paths.filter(initial.contains).filter { path in
                patchFiles.first(where: { $0.path == path }).map {
                    patchApplicabilityIssue(for: $0) == nil
                } ?? true
            }
        )
    }

    private func patchApplicabilityIssue(for file: RebasedShelfPatchFile) -> String? {
        guard isImportedShelf else { return nil }
        guard let root = repositoryRootURL else {
            return "Repository root unavailable"
        }
        guard let rawPath = Self.rawPatchPath(file.rawPatch),
              let strippedPath = RebasedPatchPathMapper.strippedPath(
                  rawPath: rawPath,
                  pathStrip: mappedPathStrip
              ) else {
            return "Invalid path strip"
        }

        let baseURL = mappedBaseDirectory.map {
            root.appendingPathComponent($0, isDirectory: true)
        } ?? root
        let targetURL = baseURL
            .appendingPathComponent(strippedPath)
            .standardizedFileURL
        guard targetURL.path == root.path || targetURL.path.hasPrefix(root.path + "/") else {
            return "Base is outside repository"
        }
        let exists = FileManager.default.fileExists(atPath: targetURL.path)
        switch file.status {
        case .added:
            return exists ? "Target already exists" : nil
        case .deleted, .modified:
            return exists ? nil : "Base file not found"
        case .renamed:
            // A rename can target a new path while its old endpoint exists;
            // the engine owns that endpoint-aware apply check.
            return nil
        }
    }

    nonisolated static func parsePatchFiles(
        _ patch: String,
        allowedPaths: [String]
    ) -> [RebasedShelfPatchFile] {
        let lines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var chunks: [(path: String, lines: [String])] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentPath, !currentLines.isEmpty else { return }
            chunks.append((currentPath, currentLines))
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = pathFromHeader(line, allowedPaths: allowedPaths)
                currentLines = [line]
            } else if line.hasPrefix("--- "),
                      index + 1 < lines.count,
                      lines[index + 1].hasPrefix("+++ ") {
                let oldPath = pathFromUnifiedHeader(line, marker: "--- ", allowedPaths: allowedPaths)
                let newPath = pathFromUnifiedHeader(lines[index + 1], marker: "+++ ", allowedPaths: allowedPaths)
                let isGitExtendedHeader = currentLines.first?.hasPrefix("diff --git ") == true
                if !isGitExtendedHeader, let path = newPath ?? oldPath {
                    flush()
                    currentPath = path
                    currentLines = [line, lines[index + 1]]
                    index += 1
                } else if currentPath != nil {
                    // A Git extended diff owns its ---/+++ headers. Do not
                    // split it into a second chunk merely because it also
                    // contains a traditional unified header pair.
                    currentLines.append(line)
                } else {
                    currentLines.append(line)
                }
            } else if currentPath != nil {
                currentLines.append(line)
            } else if line.hasPrefix("--- ") {
                // A new unified file can follow the previous file without a
                // diff --git separator. We only recognize it when its next
                // line is a valid +++ header, so hunk content such as
                // "--- value" remains part of the current patch.
                let oldPath = pathFromUnifiedHeader(line, marker: "--- ", allowedPaths: allowedPaths)
                if oldPath != nil {
                    currentPath = nil
                    currentLines = []
                }
            } else if currentPath == nil {
                // Ignore mail headers and patch metadata until a file header
                // or a Git diff boundary identifies a real change.
            }
            index += 1
        }
        flush()

        return chunks.compactMap { chunk in
            let hunkStarts = chunk.lines.indices.filter { chunk.lines[$0].hasPrefix("@@") }
            let hunks = hunkStarts.enumerated().map { offset, start in
                let end = hunkStarts.dropFirst(offset + 1).first ?? chunk.lines.count
                let lines = Array(chunk.lines[start..<end])
                return RebasedShelfPatchHunk(
                    path: chunk.path,
                    index: UInt32(offset),
                    header: lines.first ?? "Hunk \(offset + 1)",
                    preview: lines.dropFirst().prefix(3).joined(separator: "\n")
                )
            }
            let body = chunk.lines.joined(separator: "\n")
            let isBinary = body.contains("GIT binary patch") || body.contains("Binary files ")
            let status: RebasedShelfPatchStatus
            if body.contains("new file mode") || body.contains("--- /dev/null") {
                status = .added
            } else if body.contains("deleted file mode") || body.contains("+++ /dev/null") {
                status = .deleted
            } else if body.contains("rename from ") || body.contains("rename to ") {
                status = .renamed
            } else {
                status = .modified
            }
            return RebasedShelfPatchFile(
                path: chunk.path,
                hunks: hunks,
                isBinary: isBinary,
                status: status,
                rawPatch: body
            )
        }
    }

    nonisolated private static func pathFromHeader(_ line: String, allowedPaths: [String]) -> String? {
        let unquoted = line.replacingOccurrences(of: "\"", with: "")
        if let path = allowedPaths
            .sorted(by: { $0.count > $1.count })
            .first(where: { unquoted.contains("b/\($0)") || unquoted.contains("a/\($0)") }) {
            return path
        }
        guard let separator = unquoted.range(of: " b/") else { return nil }
        let path = String(unquoted[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    nonisolated private static func pathFromUnifiedHeader(
        _ line: String,
        marker: String,
        allowedPaths: [String]
    ) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        let value = String(line.dropFirst(marker.count))
            .replacingOccurrences(of: "\"", with: "")
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value != "/dev/null" else { return nil }

        if let path = allowedPaths
            .sorted(by: { $0.count > $1.count })
            .first(where: { value == $0 || value == "a/\($0)" || value == "b/\($0)" }) {
            return path
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            return String(value.dropFirst(2))
        }
        return value
    }

    nonisolated private static func defaultPathStrip(
        for patchFiles: [RebasedShelfPatchFile]
    ) -> UInt32 {
        patchFiles
            .compactMap { rawPatchPath($0.rawPatch) }
            .map { rawPath in
                UInt32(rawPath.hasPrefix("a/") || rawPath.hasPrefix("b/") ? 1 : 0)
            }
            .max() ?? 1
    }

    nonisolated private static func rawPatchPath(_ patch: String) -> String? {
        let lines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let header = lines.first(where: { $0.hasPrefix("diff --git ") }) {
            let unquoted = header.replacingOccurrences(of: "\"", with: "")
            guard let separator = unquoted.range(of: " b/") else { return nil }
            let path = String(unquoted[separator.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        if let header = lines.first(where: { $0.hasPrefix("+++ ") }),
           let path = pathFromUnifiedHeader(header, marker: "+++ ", allowedPaths: []) {
            return path
        }
        guard let header = lines.first(where: { $0.hasPrefix("--- ") }) else { return nil }
        return pathFromUnifiedHeader(header, marker: "--- ", allowedPaths: [])
    }

    nonisolated static func discoverBaseMappings(
        patchFiles: [RebasedShelfPatchFile],
        rootPath: String?,
        indexedPaths: [String],
        scope: RebasedPatchCandidateScope? = nil,
        filenameIndex: RebasedPatchFilenameIndex? = nil
    ) -> [RebasedPatchBaseCandidate] {
        guard !patchFiles.isEmpty, let rootPath, !rootPath.isEmpty else { return [] }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root.path)
        guard candidateScope.rootPath == root.path else { return [] }
        let filenameIndex = filenameIndex ?? RebasedPatchFilenameIndexStore.loadOrBuild(
            rootPath: root.path,
            indexedPaths: indexedPaths,
            scope: candidateScope
        )
        guard filenameIndex.rootPath == root.path else { return [] }

        let rawPaths = patchFiles.compactMap { rawPatchPath($0.rawPatch) }
        guard rawPaths.count == patchFiles.count else { return [] }
        let indexedItems = filenameIndex.indexedItems

        // MatchPatchPaths has a second path-finding branch for new files (or
        // existing files with no exact FilenameIndex variant). It can infer a
        // base from any indexed file/directory whose name appears in the
        // patch path, even when the trailing target directories do not exist
        // yet. A suffix-only scan misses the common "new module/new folder"
        // case and silently falls back to the wrong -p0 mapping.
        func inferredCandidates(
            rawComponents: [String],
            pathStrip: UInt32
        ) -> Set<String> {
            guard rawComponents.count > 1 else { return [] }
            var result = Set<String>()
            for index in 0..<(rawComponents.count - 1) {
                let component = rawComponents[index]
                for itemPath in indexedItems {
                    let itemComponents = itemPath.split(separator: "/").map(String.init)
                    guard itemComponents.last == component else { continue }

                    var rawIndex = index
                    var itemIndex = itemComponents.count - 1
                    var matched = 0
                    while rawIndex >= 0,
                          itemIndex >= 0,
                          rawComponents[rawIndex] == itemComponents[itemIndex] {
                        matched += 1
                        rawIndex -= 1
                        itemIndex -= 1
                    }

                    let inferredStrip = index + 1 - matched
                    guard inferredStrip < index,
                          inferredStrip == Int(pathStrip) else { continue }
                    result.insert(itemComponents.dropLast(matched).joined(separator: "/"))
                }
            }
            return result
        }

        let maximumStrip = rawPaths
            .map { $0.split(separator: "/").count }
            .max() ?? 0
        var mappings: [RebasedPatchBaseCandidate] = []
        for pathStrip in 0...UInt32(max(0, maximumStrip - 1)) {
            var commonCandidates: Set<String>?
            for rawPath in rawPaths {
                let components = rawPath.split(separator: "/").map(String.init)
                let minimumStrip = rawPath.hasPrefix("a/") || rawPath.hasPrefix("b/") ? 1 : 0
                guard pathStrip >= minimumStrip,
                      Int(pathStrip) < components.count else {
                    commonCandidates = []
                    break
                }
                let target = Array(components.dropFirst(Int(pathStrip)))
                guard !target.isEmpty else {
                    commonCandidates = []
                    break
                }
                var candidates = Set(
                    filenameIndex.files(matchingSuffix: target).map { relativeFile in
                        let fileComponents = relativeFile.split(separator: "/").map(String.init)
                        return fileComponents.dropLast(target.count).joined(separator: "/")
                    }
                )
                let targetParent = Array(target.dropLast())
                if !targetParent.isEmpty {
                    for relativeDirectory in filenameIndex.directories(matchingSuffix: targetParent) {
                        let directoryComponents = relativeDirectory.split(separator: "/").map(String.init)
                        candidates.insert(
                            directoryComponents.dropLast(targetParent.count).joined(separator: "/")
                        )
                    }
                }
                if candidates.isEmpty {
                    candidates.formUnion(
                        inferredCandidates(rawComponents: components, pathStrip: pathStrip)
                    )
                }
                commonCandidates = commonCandidates.map { $0.intersection(candidates) } ?? candidates
                if commonCandidates?.isEmpty ?? true { break }
            }
            for basePath in commonCandidates ?? [] {
                let contextScore = contextScore(
                    patchFiles: patchFiles,
                    basePath: basePath,
                    pathStrip: pathStrip,
                    root: root
                )
                let candidate = RebasedPatchBaseCandidate(
                    basePath: basePath,
                    pathStrip: pathStrip,
                    contextScore: contextScore
                )
                if let index = mappings.firstIndex(where: {
                    $0.basePath == candidate.basePath && $0.pathStrip == candidate.pathStrip
                }) {
                    if candidate.contextScore > mappings[index].contextScore {
                        mappings[index] = candidate
                    }
                } else {
                    mappings.append(candidate)
                }
            }
        }
        let allBinary = patchFiles.allSatisfy(\.isBinary)
        return mappings.sorted { lhs, rhs in
            if lhs.contextScore != rhs.contextScore { return lhs.contextScore > rhs.contextScore }
            if lhs.basePath.isEmpty != rhs.basePath.isEmpty { return lhs.basePath.isEmpty }
            if allBinary && lhs.pathStrip != rhs.pathStrip { return lhs.pathStrip < rhs.pathStrip }
            if lhs.basePath.count != rhs.basePath.count { return lhs.basePath.count < rhs.basePath.count }
            if lhs.pathStrip != rhs.pathStrip { return lhs.pathStrip < rhs.pathStrip }
            return lhs.basePath.localizedStandardCompare(rhs.basePath) == .orderedAscending
        }
    }

    nonisolated private static func contextScore(
        patchFiles: [RebasedShelfPatchFile],
        basePath: String,
        pathStrip: UInt32,
        root: URL
    ) -> Int {
        patchFiles.reduce(0) { total, file in
            guard let rawPath = rawPatchPath(file.rawPatch) else { return total }
            let components = rawPath.split(separator: "/").map(String.init)
            let strip = Int(pathStrip)
            guard strip < components.count else { return total }
            let strippedPath = components.dropFirst(strip).joined(separator: "/")
            let mappedPath = basePath.isEmpty ? strippedPath : "\(basePath)/\(strippedPath)"
            let fileURL = root.appendingPathComponent(mappedPath)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return total }
            return total + RebasedPatchContextMatcher.score(
                patch: file.rawPatch,
                text: String(text.prefix(100_000))
            )
        }
    }
}
/// IntelliJ's multi-ShelvedChangeList action chooses one target Changelist
/// before applying the selected shelves asynchronously. Keeping this chooser
/// separate from the single-shelf patch dialog preserves that interaction
/// boundary and makes the batch operation's destination explicit.
struct RebasedUnshelveMultipleDialog: View {
    let names: [String]
    let changeLists: [ChangeListInfo]
    let suggestedName: String?
    @Binding var removeAppliedFilesFromShelf: Bool
    let onUnshelve: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var targetName = ""

    private var selectedNames: [String] {
        names.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unshelve Multiple Shelves")
                .font(.title3.weight(.semibold))
            Text("Apply the selected shelves to one Changelist.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(selectedNames.joined(separator: ", "))
                .font(.headline)
                .lineLimit(2)
            Picker("Target Changelist", selection: $targetName) {
                ForEach(changeLists, id: \.name) { list in
                    Text(list.name).tag(list.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Toggle("Remove Applied Files from Shelf", isOn: $removeAppliedFilesFromShelf)
                .toggleStyle(.checkbox)
            if removeAppliedFilesFromShelf {
                Text("Applied files will be moved to Recently Deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Unshelve", action: { onUnshelve(targetName, removeAppliedFilesFromShelf) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetName.isEmpty || selectedNames.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard targetName.isEmpty else { return }
            let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            targetName = changeLists.first(where: { $0.name == suggested })?.name
                ?? changeLists.first(where: \.isActive)?.name
                ?? changeLists.first?.name
                ?? ""
        }
    }
}
