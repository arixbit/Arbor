import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


func logFilterField(
    _ title: LocalizedStringKey,
    text: Binding<String>,
    width: CGFloat? = nil
) -> some View {
    TextField(title, text: text)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .frame(width: width, height: 32)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
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
            Label(logBranchFilterTitle,
                  systemImage: "arrow.triangle.branch")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 120)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
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
    HStack(spacing: 6) {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                logPrimaryFilters
                    .frame(minWidth: geometry.size.width)
            }
        }
        logFilterActions
            .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(height: 48)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("log-filter-bar")
    .onChange(of: logList.follow) { _, _ in scheduleLogRefresh() }
}

var logPrimaryFilters: some View {
    HStack(spacing: 6) {
        logFilterField("Text or hash", text: $logList.messageFilter)
            .frame(minWidth: 100, maxWidth: .infinity)
            .accessibilityIdentifier("log-text-filter")
            .onSubmit { scheduleLogRefresh() }
        logFilterChip(".*", help: "Regex", isOn: $logList.messageRegex)
        logFilterChip("Cc", help: "Match Case", isOn: $logList.messageMatchCase)
        logPathFilterMenu
        logStartRevisionMenu
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
        Label {
            if currentPathSelections.isEmpty {
                Text("Paths")
            } else {
                Text(logPathFilterSummary(currentPathSelections))
            }
        } icon: {
            Image(systemName: currentPathSelections.isEmpty ? "folder" : "folder.fill")
        }
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .frame(maxWidth: 120)
    .padding(.horizontal, 8)
    .frame(height: 32)
    .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
    .foregroundStyle(currentPathSelections.isEmpty ? .secondary : Design.Colors.accent)
    .help("Choose or clear Paths filter")
    .accessibilityIdentifier("log-path-filter")
}

var logFilterActions: some View {
    HStack(spacing: 6) {
        logAdvancedFiltersButton
        Toggle(isOn: $logList.follow) {
            Image(systemName: "arrow.right.to.line.compact")
        }
        .toggleStyle(.checkbox)
        .help("Follow current branch")
        .accessibilityLabel("Follow current branch")
        Button {
            loadLog()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh log")
        .accessibilityLabel("Refresh log")
        if logList.isShowingCachedSnapshot {
            ProgressView()
                .controlSize(.small)
                .help("Refreshing cached history")
        }
    }
}

/// Author and date fields share a compact popover.
var logAdvancedFiltersButton: some View {
    let hasFilters = !logList.authorFilter.isEmpty
        || !logList.since.isEmpty
        || !logList.until.isEmpty
    return Button {
        logList.advancedFiltersPresented.toggle()
    } label: {
        Image(systemName: hasFilters
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle")
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 26)
            .foregroundStyle(hasFilters ? Design.Colors.accent : .secondary)
    }
    .buttonStyle(.plain)
    .help("Author and date filters")
    .accessibilityLabel("Author and date filters")
    .popover(isPresented: $logList.advancedFiltersPresented, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 10) {
            Text("Author and Date")
                .font(.system(size: 12, weight: .semibold))
            logFilterField("User", text: $logList.authorFilter, width: 220)
                .onSubmit { scheduleLogRefresh() }
            logFilterField("Since", text: $logList.since, width: 220)
                .onSubmit { scheduleLogRefresh() }
            logFilterField("Until", text: $logList.until, width: 220)
                .onSubmit { scheduleLogRefresh() }
            HStack {
                Button("Clear") {
                    logList.authorFilter = ""
                    logList.since = ""
                    logList.until = ""
                    scheduleLogRefresh()
                }
                .disabled(!hasFilters)
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
}

}
