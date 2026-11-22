import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


func logFilterField(
    _ title: LocalizedStringKey,
    text: Binding<String>,
    width: CGFloat? = nil,
    showsSearchIcon: Bool = false,
    drawsChrome: Bool = true
) -> some View {
    TextField(title, text: text)
        .textFieldStyle(.plain)
        .padding(.leading, showsSearchIcon ? 24 : 10)
        .padding(.trailing, 10)
        .frame(width: width, height: 28)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background {
            if drawsChrome {
                RoundedRectangle(cornerRadius: 4).fill(Design.Colors.surface)
            }
        }
        .overlay(alignment: .leading) {
            if showsSearchIcon {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if drawsChrome {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1)
            }
        }
}


/// Log 左侧的起始 revision / 分支过滤菜单。
///
/// `logGraphPanel` 单个表达式过大，类型检查会超时；把这块单独成属性。
var logStartRevisionMenu: some View {
        Menu {
            Button("HEAD") { setLogStartRevisions([]) }
            Button("Enter branch, tag, or commit") {
                logList.revisionInput = ""
                logList.revisionFilterPresented = true
            }
            Divider()
            Section("Local Branches") {
                ForEach(branchWorkspace.branches, id: \.name) { branch in
                    Toggle(
                        isOn: logStartRevisionBinding(for: branch.name)
                    ) {
                        Text(branch.name)
                    }
                }
            }
            if !branchWorkspace.remoteBranches.isEmpty {
                Section("Remote Branches") {
                    ForEach(branchWorkspace.remoteBranches, id: \.name) { branch in
                        Toggle(
                            isOn: logStartRevisionBinding(for: branch.name)
                        ) {
                            Text(branch.name)
                        }
                    }
                }
            }
            if !tagWorkspace.tags.isEmpty {
                Section("Tags") {
                    ForEach(tagWorkspace.tags, id: \.name) { tag in
                        Toggle(
                            isOn: logStartRevisionBinding(for: tag.name)
                        ) {
                            Text(tag.name)
                        }
                    }
                }
            }
        } label: {
            Group {
                if logList.startRevisions.isEmpty { Text("Branch") }
                else { Text(logBranchFilterTitle) }
            }
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 72, alignment: .leading)
        .frame(height: 28)
        .help(logBranchFilterTitle)
        .accessibilityIdentifier("log-branch-filter")
        .onChange(of: logList.startRevisions) { _, _ in scheduleLogRefresh() }
}


/// Small toggle chip used by the compact filter row (`.*`, `Cc`).
func logFilterChip(
    _ title: String,
    help: LocalizedStringKey,
    isOn: Binding<Bool>
) -> some View {
    Button {
        isOn.wrappedValue.toggle()
    } label: {
        Text(title)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .frame(minWidth: 26, minHeight: 24)
            .background(
                isOn.wrappedValue ? Design.Colors.accent.opacity(0.16) : Design.Colors.surface,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(isOn.wrappedValue ? Design.Colors.accent : .secondary)
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
}

/// Keep actions visible even when the Log column is too narrow for the filters.
var logFilterBar: some View {
    GeometryReader { geometry in
        HStack(spacing: 4) {
            if !logBranchesVisible {
                Button {
                    logBranchesVisible = true
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Show Branches")
                .accessibilityLabel("Show Branches")
            }
            logPrimaryFilters
                .layoutPriority(-1)
            logGraphOptionsButton
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)
            Button {
                openAnotherLogTab()
            } label: {
                newLogTabIcon()
            }
            .buttonStyle(.borderless)
            .help("Open New Git Log Tab")
            .accessibilityLabel("Open New Git Log Tab")
            .disabled(projectWorkspace.repository == nil)
            Spacer(minLength: 16)
            logFilterActions
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .frame(width: geometry.size.width, height: 40, alignment: .leading)
    }
    .frame(height: 40)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("log-filter-bar")
    .onChange(of: logList.follow) { _, _ in scheduleLogRefresh() }

}

var logPrimaryFilters: some View {
    HStack(spacing: 4) {
        HStack(spacing: 2) {
            logFilterField("Text or hash", text: $logList.messageFilter, showsSearchIcon: true, drawsChrome: false)
                .frame(minWidth: 96, idealWidth: 188, maxWidth: 280)
                .accessibilityIdentifier("log-text-filter")
                .accessibilityLabel("Filter commits")
                .onSubmit { scheduleLogRefresh() }
            logFilterChip(".*", help: "Regex", isOn: $logList.messageRegex)
            logFilterChip("Cc", help: "Match Case", isOn: $logList.messageMatchCase)
        }
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1) }
        logStartRevisionMenu
        logUserFilterButton
        logDateFilterButton
        logPathFilterMenu
    }
}

var logPathFilterMenu: some View {
    let currentPathSelections = activeLogPathFilterSelections()
    return Menu {
        Button("Edit Paths…") { openLogPathsEditor() }
        Button("Select Paths in Tree…") { openLogPathsTreeChooser() }
            .disabled(logStructureFilterRootPaths.isEmpty && availableReflogRootPaths.isEmpty)
        Button("Choose…") { chooseLogPathFilter() }
            .disabled(availableReflogRootPaths.isEmpty)
        if logStructureFilterRootPaths.count > 1 {
            Divider()
            Section("Repositories") {
                ForEach(logStructureFilterRootPaths, id: \.self) { rootPath in
                    Toggle(
                        isOn: Binding(
                            get: { visibleLogStructureFilterRootPaths.contains(rootPath) },
                            set: { setLogStructureFilterRoot(rootPath, visible: $0) }
                        )
                    ) {
                        Text(URL(fileURLWithPath: rootPath).lastPathComponent)
                            .help(rootPath)
                    }
                }
            }
        }
        let recent = recentLogPathFilterSelections()
        if !recent.isEmpty {
            Divider()
            Section("Recent Filters") {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, paths in
                    Button(logPathFilterSummary(paths)) {
                        setLogPathFilterSelections(paths, remember: false)
                    }
                }
                Button("Clear Recent Filters") {
                    clearRecentLogPathFilters()
                }
            }
        }
        if !currentPathSelections.isEmpty {
            Divider()
            Button("Clear") { clearLogPathFilter() }
        }
    } label: {
        Group {
            if currentPathSelections.isEmpty {
                Text("Paths")
            } else {
                Text(logPathFilterSummary(currentPathSelections))
            }
        }
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .frame(width: 72, alignment: .leading)
    .frame(height: 28)
    .foregroundStyle(currentPathSelections.isEmpty ? .secondary : Design.Colors.accent)
    .help("Choose or clear Paths filter")
    .accessibilityIdentifier("log-path-filter")
}

var logPresentationOptionsButton: some View {
    Menu {
        Toggle("Show Commit Details", isOn: $logShowDetails)
        Toggle("Show Diff Preview", isOn: $logShowDiffPreview)
        Toggle("Show Column Headers", isOn: $logShowColumnHeaders)
        Toggle("Show Author and Date", isOn: showAuthorAndDateBinding)
        Toggle("Show Commit Hash", isOn: $logShowHashColumn)
        Toggle("Follow current branch", isOn: $logList.follow)
    } label: {
        eyeMenuIcon()
            .frame(width: 18, height: 16)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("View Options")
    .accessibilityLabel("View Options")
    .accessibilityIdentifier("log-view-options")
}

var logGraphOptionsButton: some View {
    Menu {
        Toggle("Compact References", isOn: $logCompactReferences)
        Toggle("Show Long Edges", isOn: $logShowLongEdges)
        Toggle("Align Labels", isOn: $logAlignLabels)
        Toggle("Collapse Graph", isOn: $logCollapseGraph)
        Button("Collapse All Graph") { issueLogGraphCommand(.buttonCollapse) }
            .disabled(logList.viewMode != .graph)
        Button("Expand All Graph") { issueLogGraphCommand(.buttonExpand) }
            .disabled(logList.viewMode != .graph)
    } label: {
        graphOptionsIcon()
            .frame(width: 22, height: 22)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Graph Options")
    .accessibilityLabel("Graph Options")
}

var logFilterActions: some View {
    HStack(spacing: 2) {
        Button {
            let isReflog = logList.viewMode == .reflog
            loadLog()
            let generation = isReflog ? reflog.generation : logList.generation
            if let task = isReflog ? reflog.loadTask : logList.loadTask {
                Task { @MainActor in
                    await task.value
                    guard !task.isCancelled,
                          generation == (isReflog ? reflog.generation : logList.generation),
                          logList.error == nil else { return }
                    feedbackCenter.success("Log refreshed")
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderless)
        .help("Refresh log")
        .accessibilityLabel("Refresh log")
        Button {
            if let selectedCommit { cherryPickFromLog(selectedCommit) }
        } label: {
            cherryPickIcon()
        }
        .buttonStyle(.borderless)
        .help("Cherry-Pick")
        .accessibilityLabel("Cherry-Pick")
        .disabled(selectedCommit == nil || logSelectionState.selectedIDs.count != 1)
        logPresentationOptionsButton
        Button(action: goToHashBranchOrTag) {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Go To Hash/Branch/Tag")
        .accessibilityLabel("Go To Hash/Branch/Tag")
        if logList.isShowingCachedSnapshot {
            ProgressView()
                .controlSize(.small)
                .help("Refreshing cached history")
        }
    }
}

/// Separate, named entries match the visible filter order in the reference.
var logUserFilterButton: some View {
    Button {
        logList.advancedFiltersPresented.toggle()
    } label: {
        HStack(spacing: 4) {
            Text("User")
            Image(systemName: "chevron.down").font(.system(size: 9))
        }
        .foregroundStyle(logList.authorFilter.isEmpty ? .secondary : Design.Colors.accent)
        .frame(height: 28)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("log-user-filter")
    .popover(isPresented: $logList.advancedFiltersPresented, arrowEdge: .bottom) {
        logUserFilterEditor
    }
}

var logUserFilterEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("User").font(.headline)
        logFilterField("User", text: $logList.authorFilter, width: 220)
            .onSubmit { scheduleLogRefresh() }
        HStack {
            Button("Clear") {
                logList.authorFilter = ""
                scheduleLogRefresh()
            }
            .disabled(logList.authorFilter.isEmpty)
            Spacer()
            Button("Done") {
                logList.advancedFiltersPresented = false
                scheduleLogRefresh()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
    .padding(14)
    .frame(width: 260)
}

var logDateFilterButton: some View {
    let hasFilters = !logList.since.isEmpty || !logList.until.isEmpty
    return Button {
        logList.dateFiltersPresented.toggle()
    } label: {
        HStack(spacing: 4) {
            Text("Date")
            Image(systemName: "chevron.down").font(.system(size: 9))
        }
        .foregroundStyle(hasFilters ? Design.Colors.accent : .secondary)
        .frame(height: 28)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("log-date-filter")
    .popover(isPresented: $logList.dateFiltersPresented, arrowEdge: .bottom) {
        logDateFilterEditor
    }
}

var logDateFilterEditor: some View {
    let hasFilters = !logList.since.isEmpty || !logList.until.isEmpty
    return VStack(alignment: .leading, spacing: 10) {
        Text("Date").font(.headline)
        logFilterField("Since", text: $logList.since, width: 220)
            .onSubmit { scheduleLogRefresh() }
        logFilterField("Until", text: $logList.until, width: 220)
            .onSubmit { scheduleLogRefresh() }
        HStack {
            Button("Clear") {
                logList.since = ""
                logList.until = ""
                scheduleLogRefresh()
            }
            .disabled(!hasFilters)
            Spacer()
            Button("Done") {
                logList.dateFiltersPresented = false
                scheduleLogRefresh()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
    .padding(14)
    .frame(width: 260)
}

func cherryPickIcon() -> Image {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        let color = NSColor.secondaryLabelColor
        color.setStroke()
        for origin in [NSPoint(x: 0.8, y: 1.0), NSPoint(x: 7.4, y: 1.0)] {
            let fruit = NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: 6.6, height: 6.6)))
            fruit.lineWidth = 1.2
            fruit.stroke()
        }
        let stems = NSBezierPath()
        stems.lineWidth = 1.2
        stems.lineCapStyle = .round
        stems.move(to: NSPoint(x: 4.0, y: 7.2))
        stems.curve(to: NSPoint(x: 8.2, y: 14.4),
                    controlPoint1: NSPoint(x: 4.6, y: 10.4),
                    controlPoint2: NSPoint(x: 6.4, y: 13.2))
        stems.move(to: NSPoint(x: 10.6, y: 7.2))
        stems.curve(to: NSPoint(x: 8.2, y: 14.4),
                    controlPoint1: NSPoint(x: 10.2, y: 10.4),
                    controlPoint2: NSPoint(x: 9.2, y: 13.2))
        stems.stroke()
        return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
}

/// Rebased's graph-options mark is a down arrow beside two nodes, with the
/// menu triangle in the corner. `arrow.up.arrow.down` reads as a different control.
func graphOptionsIcon() -> Image {
    let size = NSSize(width: 18, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        let color = NSColor.secondaryLabelColor
        color.setStroke()
        color.setFill()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 3.2, y: 12.2))
        arrow.line(to: NSPoint(x: 3.2, y: 3.2))
        arrow.move(to: NSPoint(x: 1.2, y: 5.4))
        arrow.line(to: NSPoint(x: 3.2, y: 3.2))
        arrow.line(to: NSPoint(x: 5.2, y: 5.4))
        arrow.stroke()
        let spine = NSBezierPath()
        spine.lineWidth = 1.15
        spine.move(to: NSPoint(x: 9.2, y: 12.4))
        spine.line(to: NSPoint(x: 9.2, y: 3.4))
        spine.stroke()
        let upper = NSBezierPath(ovalIn: NSRect(x: 7.7, y: 9.6, width: 3, height: 3))
        upper.lineWidth = 1.15
        upper.stroke()
        let lower = NSBezierPath(ovalIn: NSRect(x: 7.7, y: 4.2, width: 3, height: 3))
        lower.lineWidth = 1.15
        lower.stroke()
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: 13.2, y: 4.6))
        mark.line(to: NSPoint(x: 16.4, y: 1.4))
        mark.line(to: NSPoint(x: 13.2, y: 1.4))
        mark.close()
        mark.fill()
        return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
}

func newLogTabIcon() -> Image {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        let color = NSColor.secondaryLabelColor
        color.setStroke()
        let frame = NSBezierPath()
        frame.lineWidth = 1.25
        frame.lineCapStyle = .round
        frame.lineJoinStyle = .round
        // Open rectangle with the plus sitting on the missing top-right corner.
        frame.move(to: NSPoint(x: 1.6, y: 2.2))
        frame.line(to: NSPoint(x: 1.6, y: 11.0))
        frame.line(to: NSPoint(x: 7.4, y: 11.0))
        frame.move(to: NSPoint(x: 1.6, y: 2.2))
        frame.line(to: NSPoint(x: 10.6, y: 2.2))
        frame.stroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.35
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: 11.4, y: 14.2))
        plus.line(to: NSPoint(x: 11.4, y: 8.0))
        plus.move(to: NSPoint(x: 8.4, y: 11.1))
        plus.line(to: NSPoint(x: 14.4, y: 11.1))
        plus.stroke()
        return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
}

}
