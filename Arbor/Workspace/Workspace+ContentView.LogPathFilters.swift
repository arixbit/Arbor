import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Paths structure-filter state is stored as recent groups of normalized,
/// root-qualified selections. Legacy `[[String]]` values are still accepted
/// and become shared selections that apply to every visible Git root.
func activeLogPathFilterSelections() -> [LogPathFilterSelection] {
    let normalized = normalizedLogPathFilterSelections(logList.pathFilterSelections)
    if !normalized.isEmpty {
        return normalized
    }
    return makeLogPathFilterSelections(from: normalizedLogPathFilters(logList.pathFilter))
}

func recentLogPathFilterSelections() -> [[LogPathFilterSelection]] {
    guard let data = logRecentPathFiltersRaw.data(using: .utf8) else { return [] }
    if let decoded = try? JSONDecoder().decode([[LogPathFilterSelection]].self, from: data) {
        return decoded.compactMap { values in
            let normalized = normalizedLogPathFilterSelections(values)
            return normalized.isEmpty ? nil : normalized
        }
    }
    guard let legacy = try? JSONDecoder().decode([[String]].self, from: data) else {
        return []
    }
    return legacy.compactMap { values in
        let normalized = makeLogPathFilterSelections(from: normalizedLogPathFilters(values.joined(separator: "\n")))
        return normalized.isEmpty ? nil : normalized
    }
}

func rememberLogPathFilterSelections(_ selections: [LogPathFilterSelection]) {
    let normalized = normalizedLogPathFilterSelections(selections)
    guard !normalized.isEmpty else { return }
    let updated = ([normalized] + recentLogPathFilterSelections().filter { $0 != normalized }).prefix(10)
    guard let data = try? JSONEncoder().encode(Array(updated)) else { return }
    logRecentPathFiltersRaw = String(decoding: data, as: UTF8.self)
}

func setLogPathFilterSelections(
    _ selections: [LogPathFilterSelection],
    remember: Bool = true
) {
    let normalized = normalizedLogPathFilterSelections(selections)
    if let projectPath = projectWorkspace.path,
       logSelectionState.tabs.first(where: { $0.id == currentLogTabID })?.updateInfoRanges != nil {
        GitUpdateInfoPathFilterSettings.save(
            logPathFilterEditorText(normalized),
            roots: logStructureFilterRootPaths,
            for: projectPath
        )
    }
    logList.pathFilterSelections = normalized
    logList.pathFilter = logPathFilterEditorText(normalized)
    if remember {
        rememberLogPathFilterSelections(normalized)
    }
    scheduleLogRefresh()
}

func setLogPathFilterPaths(_ paths: [String], remember: Bool = true) {
    setLogPathFilterSelections(makeLogPathFilterSelections(from: paths), remember: remember)
}

func openLogPathsEditor() {
    logList.pathsEditorText = logPathFilterEditorText(activeLogPathFilterSelections())
    logList.pathsEditorPresented = true
}

func clearRecentLogPathFilters() {
    logRecentPathFiltersRaw = ""
}

func logPathTreeSelections() -> Set<LogPathFilterSelection> {
    let roots = normalizedLogRootPaths(
        logStructureFilterRootPaths.isEmpty ? availableReflogRootPaths : logStructureFilterRootPaths
    )
    var result = Set<LogPathFilterSelection>()
    for selection in activeLogPathFilterSelections() {
        if let rootPath = selection.rootPath {
            if roots.contains(rootPath) {
                result.insert(selection)
            }
        } else {
            for rootPath in roots {
                result.insert(LogPathFilterSelection(rootPath: rootPath, path: selection.path))
            }
        }
    }
    return normalizedLogTreeSelections(Array(result))
}

func openLogPathsTreeChooser() {
    let rootPaths = normalizedLogRootPaths(
        logStructureFilterRootPaths.isEmpty ? availableReflogRootPaths : logStructureFilterRootPaths
    )
    let roots = rootPaths.compactMap { rootPath -> LogPathChooserRoot? in
        guard let repository = try? openRepository(path: rootPath) else { return nil }
        return LogPathChooserRoot(path: rootPath, repository: repository)
    }
    guard !roots.isEmpty else {
        feedbackCenter.warning(
            "Paths filter unavailable",
            detail: "No Git root is available for selecting a path.",
            nextStep: "Open or refresh a Git repository and retry.",
            localized: false
        )
        return
    }
    logList.pathsTreeChooserRoots = roots
    logList.pathsTreeChooserSelections = logPathTreeSelections()
    logList.pathsTreeChooserPresented = true
}

var logStructureFilterRootPaths: [String] {
    if isLogAggregate {
        return normalizedLogRootPaths(
            logRuntime.aggregateBranchFilters.map(\.rootPath)
                + logRuntime.aggregateRevisionRanges.map(\.rootPath)
                + Array(logRuntime.aggregateRootPaths)
        )
    }
    return normalizedLogRootPaths([logRepository?.workdir()].compactMap { $0 })
}

var visibleLogStructureFilterRootPaths: Set<String> {
    reconciledLogVisibleRootPaths(
        allRoots: logStructureFilterRootPaths,
        raw: logVisibleRootFilterRaw(for: logStructureFilterRootPaths)
    )
}

func logVisibleRootPersistenceScope(_ roots: [String]) -> String {
    normalizedLogRootPaths(roots).joined(separator: "\u{1f}")
}

func persistedLogVisibleRootPaths(for roots: [String]) -> Set<String>? {
    guard let data = logVisibleRootPathsPersistedRaw.data(using: .utf8),
          let values = try? JSONDecoder().decode([String: [String]].self, from: data),
          let selected = values[logVisibleRootPersistenceScope(roots)] else {
        return nil
    }
    return Set(normalizedLogRootPaths(selected)).intersection(normalizedLogRootPaths(roots))
}

func logVisibleRootFilterRaw(for roots: [String]) -> String {
    guard logList.visibleRootPathsRaw.isEmpty,
          let selected = persistedLogVisibleRootPaths(for: roots) else {
        return logList.visibleRootPathsRaw
    }
    return serializedLogVisibleRootPaths(selected: selected, allRoots: roots)
}

func persistLogVisibleRootPaths(selected: Set<String>, allRoots: [String]) {
    let normalizedRoots = normalizedLogRootPaths(allRoots)
    let scope = logVisibleRootPersistenceScope(normalizedRoots)
    guard !scope.isEmpty else { return }
    var values = (try? JSONDecoder().decode(
        [String: [String]].self,
        from: logVisibleRootPathsPersistedRaw.data(using: .utf8) ?? Data()
    )) ?? [:]
    if selected == Set(normalizedRoots) {
        values.removeValue(forKey: scope)
    } else {
        values[scope] = normalizedLogRootPaths(Array(selected.intersection(Set(normalizedRoots))))
    }
    guard let data = try? JSONEncoder().encode(values) else { return }
    logVisibleRootPathsPersistedRaw = String(decoding: data, as: UTF8.self)
}

func setLogStructureFilterRoot(_ rootPath: String, visible: Bool) {
    let allRoots = logStructureFilterRootPaths
    guard allRoots.contains(rootPath) else { return }
    var selected = visibleLogStructureFilterRootPaths
    if visible {
        selected.insert(rootPath)
    } else {
        guard selected.count > 1 else { return }
        selected.remove(rootPath)
    }
    logList.visibleRootPathsRaw = serializedLogVisibleRootPaths(selected: selected, allRoots: allRoots)
    persistLogVisibleRootPaths(selected: selected, allRoots: allRoots)
    loadLog()
}

func chooseLogPathFilter() {
    let roots = logStructureFilterRootPaths.isEmpty
        ? availableReflogRootPaths
        : logStructureFilterRootPaths
    guard let firstRoot = roots.first else {
        feedbackCenter.warning(
            "Paths filter unavailable",
            detail: "No Git root is available for selecting a path.",
            nextStep: "Open or refresh a Git repository and retry.",
            localized: false
        )
        return
    }

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.prompt = "Select Path"
    panel.directoryURL = URL(fileURLWithPath: logRepository?.workdir() ?? firstRoot)
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

    let normalizedRoots = logRootPathsDeepestFirst(roots)
    var selections: [LogPathFilterSelection] = []
    for url in panel.urls {
        guard let filter = relativeLogPathFilter(for: url, roots: roots) else {
            feedbackCenter.warning(
                "Path is outside the Git roots",
                detail: url.standardizedFileURL.path,
                nextStep: "Select files or folders inside one of the project's Git roots.",
                localized: false
            )
            return
        }
        if !filter.isEmpty {
            let selectedPath = url.standardizedFileURL.path
            let rootPath = normalizedRoots.first(where: {
                selectedPath == $0 || selectedPath.hasPrefix($0 + "/")
            })
            selections.append(LogPathFilterSelection(rootPath: rootPath, path: filter))
        }
    }
    guard !selections.isEmpty else {
        setLogPathFilterPaths([])
        return
    }
    setLogPathFilterSelections(activeLogPathFilterSelections() + selections)
}

func clearLogPathFilter() {
    guard !activeLogPathFilterSelections().isEmpty else { return }
    setLogPathFilterSelections([], remember: false)
}

}
