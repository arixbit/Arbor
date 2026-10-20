import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


func logFilterField(
    _ title: LocalizedStringKey,
    text: Binding<String>,
    width: CGFloat
) -> some View {
    TextField(title, text: text)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .frame(width: width, height: 32)
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
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: logList.startRevisions) { _, _ in scheduleLogRefresh() }
}


/// Log 过滤条（文本 / 分支 / 作者 / 路径 / 时间范围 / Follow）。
///
/// 单独成属性避免 `logGraphPanel` 的单个表达式超出类型检查预算。
var logFilterBar: some View {
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 6) {
        logFilterField("Text or hash", text: $logList.messageFilter, width: 215)
            .onSubmit { scheduleLogRefresh() }
        Menu {
            Toggle("Regex", isOn: $logList.messageRegex)
            Toggle("Match Case", isOn: $logList.messageMatchCase)
            Divider()
            Button("Clear Text Filter") {
                logList.messageFilter = ""
                scheduleLogRefresh()
            }
            .disabled(logList.messageFilter.isEmpty)
        } label: {
            Label("Text Filter Settings", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle((logList.messageRegex || logList.messageMatchCase) ? Design.Colors.accent : .secondary)
        .help("Text Filter Settings")
        HStack(spacing: 4) {
            let currentPathSelections = activeLogPathFilterSelections()
            if currentPathSelections.count > 1 {
                Button {
                    openLogPathsEditor()
                } label: {
                    Text(logPathFilterSummary(currentPathSelections))
                        .lineLimit(1)
                        .frame(width: 150, height: 32, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                logFilterField("Paths", text: $logList.pathFilter, width: 150)
                    .onSubmit { applyManualLogPathFilter() }
            }
            Menu {
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
                Image(systemName: currentPathSelections.isEmpty
                      ? "folder"
                      : "folder.fill")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(currentPathSelections.isEmpty ? .secondary : Design.Colors.accent)
            .help("Choose or clear Paths filter")
        }
        logStartRevisionMenu
        logFilterField("User", text: $logList.authorFilter, width: 110)
            .onSubmit { scheduleLogRefresh() }
        logFilterField("Since", text: $logList.since, width: 120)
            .onSubmit { scheduleLogRefresh() }
        logFilterField("Until", text: $logList.until, width: 120)
            .onSubmit { scheduleLogRefresh() }
        Toggle(isOn: $logList.follow) {
            Image(systemName: "arrow.right.to.line.compact")
        }
        .toggleStyle(.checkbox)
        .help("Follow current branch")
        Button {
            loadLog()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh log")
        if logList.isShowingCachedSnapshot {
            ProgressView()
                .controlSize(.small)
                .help("Refreshing cached history")
        }
    }
    // The filter row belongs to the commit-table column, not to the
    // graph gutter. Rebased keeps the fields aligned with the first
    // commit summary while the colored lanes remain visible below.
    .padding(.leading, 10)
    .padding(.trailing, 10)
    .padding(.vertical, 8)
}
.frame(height: 48)
.onChange(of: logList.follow) { _, _ in scheduleLogRefresh() }
}

}
