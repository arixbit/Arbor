import SwiftUI
import AppKit


enum LogViewMode: String, CaseIterable, Identifiable, Codable {
    case graph
    case command
    case compare
    case compareBranches
    case tags
    case reflog
    var id: String { rawValue }
}

enum LogGraphSortChoice: String, CaseIterable, Identifiable {
    case byCommitDate
    case topologically
    case linearizeMerges
    case firstParent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byCommitDate: "Normal (Off)"
        case .topologically: "Standard (Bek)"
        case .linearizeMerges: "Linear (LinearBek)"
        case .firstParent: "First Parent"
        }
    }

    var engineValue: LogGraphSortMode {
        switch self {
        case .byCommitDate: .byCommitDate
        case .topologically: .topologically
        case .linearizeMerges: .linearizeMerges
        case .firstParent: .firstParent
        }
    }
}

/// Expected-state context for undoing a successful Log Drop/Extract rewrite.
/// Unlike a plain ref move, the rewrite changes commit trees, so the undo
/// restores the complete branch tip with `reset --keep` and refuses stale
/// notifications using both HEAD and symbolic-branch identity.
struct LogSelectedChangesUndoTarget: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let initialHead: String
    let expectedHead: String
}

struct LogTabDescriptor: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Log"
    /// A tab can retain a root-qualified Log context even when the root is the
    /// primary repository. Optional keeps older persisted external tabs
    /// decodable.
    var rootPath: String?
    /// Non-nil marks a dedicated File History tab. It lets the tab lifecycle
    /// reuse an existing history session instead of duplicating it.
    var historyPath: String?
    /// Non-nil marks IntelliJ's dedicated Update Info Log tab. The ranges
    /// remain root-qualified so switching tabs cannot turn a multi-root update
    /// into a primary-repository-only query.
    var updateInfoRanges: [PersistedLogRevisionRange]?
    /// Aggregate Log filters belong to the tab that created them. Optional
    /// fields preserve older persisted external tabs while allowing Update
    /// Info and ordinary multi-root tabs to switch without leaking state.
    var aggregateBranchFilters: [LogRootBranchFilter]?
    var aggregateRevisionRanges: [PersistedLogRevisionRange]?
    var aggregateRootPaths: [String]?
    var viewMode: LogViewMode = .graph
    var startRevision = ""
    var startRevisions: [String] = []
    var pathFilter = ""
    var pathSelections: [LogPathFilterSelection] = []
    var visibleRootPathsRaw = ""
    var authorFilter = ""
    var messageFilter = ""
    var messageRegex = false
    var messageMatchCase = false
    var sinceText = ""
    var untilText = ""
    var commandFilter = ""
    var follow = false
    var graphSortModeRaw = LogGraphSortChoice.byCommitDate.rawValue
    var compareRevision1 = ""
    var compareRevision2 = ""
    var compareRepositoryPath: String?
    var compareWithWorkingTree = false
    /// Compare panes are separate VcsLog UIs in IntelliJ. Keep their filters
    /// tab-local so opening or switching a comparison cannot leak predicates
    /// from another branch pair.
    var compareFirstFilter: BranchComparisonFilter?
    var compareSecondFilter: BranchComparisonFilter?
    var selection: String?
    var selectedIDs: Set<String> = []
    /// Reflog is a root-scoped view rather than an aggregate Log filter. Keep
    /// its repository and selection separate so switching tabs cannot silently
    /// move the Reflog to the primary root. Optional fields preserve decoding
    /// of tabs persisted before Reflog context became tab-local.
    var reflogRootPath: String?
    var reflogSelection: String?
    var reflogSelectedIDs: [String]?
}

/// Build the persisted state for IntelliJ's tabbed File History entry point.
/// The path remains root-qualified so opening the same relative path from a
/// nested Git root cannot silently query the primary repository.
func makeFileHistoryLogTab(
    path: String,
    startRevision: String,
    rootPath: String?
) -> LogTabDescriptor {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRevision = startRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveRevision = normalizedRevision.isEmpty ? "HEAD" : normalizedRevision
    let normalizedRoot = rootPath
        .map(canonicalExternalLogPath)
        .flatMap { $0.isEmpty ? nil : $0 }
    let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent
    var tab = LogTabDescriptor()
    tab.title = "History: \(fileName.isEmpty ? normalizedPath : fileName)"
    tab.rootPath = normalizedRoot
    tab.historyPath = normalizedPath
    tab.viewMode = .graph
    tab.startRevision = effectiveRevision
    tab.startRevisions = [effectiveRevision]
    tab.pathFilter = normalizedPath
    tab.pathSelections = [
        LogPathFilterSelection(rootPath: normalizedRoot, path: normalizedPath)
    ]
    tab.follow = true
    return tab
}

/// Build the dedicated Log tab used by IntelliJ's Update Info notification.
/// Reusing this shape for Update, Pull, Push recovery, and Merge keeps the
/// View Commits action root-qualified without replacing the user's ordinary
/// Log tab.
func makeUpdateInfoLogTab(
    ranges: [PersistedLogRevisionRange],
    title: String = "Update Info"
) -> LogTabDescriptor {
    var tab = LogTabDescriptor()
    tab.title = title
    tab.rootPath = ranges.count == 1 ? ranges[0].rootPath : nil
    tab.updateInfoRanges = ranges
    tab.aggregateRevisionRanges = ranges
    return tab
}

struct ExternalLogTabsState: Codable, Equatable {
    var tabs: [LogTabDescriptor]
    var activeTabID: UUID?

    func sanitized() -> ExternalLogTabsState {
        var seen = Set<UUID>()
        let uniqueTabs = tabs.filter { seen.insert($0.id).inserted }
        let activeID = activeTabID.flatMap { id in
            uniqueTabs.contains(where: { $0.id == id }) ? id : nil
        } ?? uniqueTabs.first?.id
        return ExternalLogTabsState(tabs: uniqueTabs, activeTabID: activeID)
    }
}

enum ExternalLogTabsStore {
    static let keyPrefix = "arbor.externalLog.tabs.v1."

    static func key(projectPath: String, rootPaths: Set<String>) -> String {
        let roots = normalizedLogRootPaths(Array(rootPaths)).joined(separator: "\u{1f}")
        return keyPrefix + canonicalExternalLogPath(projectPath) + "\u{1e}" + roots
    }

    static func load(projectPath: String, rootPaths: Set<String>) -> ExternalLogTabsState? {
        load(key: key(projectPath: projectPath, rootPaths: rootPaths))
    }

    static func load(key: String) -> ExternalLogTabsState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExternalLogTabsState.self, from: data)
    }

    static func save(
        _ state: ExternalLogTabsState,
        projectPath: String,
        rootPaths: Set<String>
    ) {
        save(state, key: key(projectPath: projectPath, rootPaths: rootPaths))
    }

    static func save(_ state: ExternalLogTabsState, key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// IntelliJ's structure filter keeps each FilePath tied to its owning Git
/// root. A bare relative path is retained as a compatibility form for paths
/// entered manually and applies to every selected root.
struct LogPathFilterSelection: Codable, Equatable, Hashable, Sendable, Identifiable {
    let rootPath: String?
    let path: String

    var id: String {
        "\(rootPath ?? "")\u{1f}\(path)"
    }
}

/// A repository handle used by the lazy VCS structure chooser. It is kept out
/// of LogPathFilterSelection so persisted filter state never captures a live
/// FFI object.
struct LogPathChooserRoot: Identifiable {
    let path: String
    let repository: Repository

    var id: String { path }

    var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// A root-qualified revision range used by update-session history actions.
/// This is separate from branch dashboard filters so a range opened from a
/// notification cannot be mistaken for a branch name by the UI.
struct LogRootRevisionRange: Equatable, Hashable, Sendable {
    let rootPath: String
    let oldRevision: String
    let newRevision: String

    init(rootPath: String, oldRevision: String, newRevision: String) {
        self.rootPath = rootPath
        self.oldRevision = oldRevision
        self.newRevision = newRevision
    }

    init(_ persisted: PersistedLogRevisionRange) {
        rootPath = persisted.rootPath
        oldRevision = persisted.oldRevision
        newRevision = persisted.newRevision
    }

    var persisted: PersistedLogRevisionRange {
        PersistedLogRevisionRange(
            rootPath: rootPath,
            oldRevision: oldRevision,
            newRevision: newRevision
        )
    }
}

/// A current-revision description is pinned to the Git root that resolved
/// the project-tree path. The request must not fall back to the active Log
/// repository when a nested Git root owns the selected file.
struct CurrentRevisionRequest: Identifiable {
    let repo: Repository
    let path: String
    let commit: CommitInfo

    var id: String { "\(repo.workdir() ?? ""): \(path):\(commit.id)" }
}
