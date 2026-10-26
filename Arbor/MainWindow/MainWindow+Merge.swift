import SwiftUI
import AppKit



func firstConflictedPath(in entries: [FileEntry]) -> String? {
    for entry in entries {
        let stagedIsConflict = entry.staged == .conflicted
        let unstagedIsConflict = entry.unstaged == .conflicted
        if stagedIsConflict || unstagedIsConflict {
            return entry.path
        }
    }
    return nil
}

struct MultiRootMergeRollbackTarget: Identifiable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let operationPending: Bool

    var id: String { "\(rootPath):\(initialHead):\(expectedHead)" }
}

struct MultiRootMergeRollbackContext: Identifiable {
    let branchName: String
    let targets: [MultiRootMergeRollbackTarget]
    let failures: [String]
    let pendingRootPath: String?

    var id: String {
        "multi-root-merge:\(branchName):\(targets.map(\.id).joined(separator: "|")):\(pendingRootPath ?? "")"
    }
}

struct MultiRootMergePresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var selectedRootPaths: Set<String>
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    @Binding var rollbackContext: MultiRootMergeRollbackContext?
    let locale: Locale
    let branchName: String
    let snapshots: [GitRootBranchSnapshot]
    let mergedBranchesByRoot: [String: Set<String>]
    let onMerge: () -> Void
    let onCancel: () -> Void
    let onRollback: ([MultiRootMergeRollbackTarget]) -> Void
    let onKeep: (MultiRootMergeRollbackContext) -> Void
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                RebasedMultiRootMergeDialog(
                    branchName: branchName,
                    selectedRootPaths: $selectedRootPaths,
                    strategy: $strategy,
                    commitMessage: $commitMessage,
                    useCustomCommitMessage: $useCustomCommitMessage,
                    noCommit: $noCommit,
                    noVerify: $noVerify,
                    allowUnrelatedHistories: $allowUnrelatedHistories,
                    snapshots: snapshots,
                    mergedBranchesByRoot: mergedBranchesByRoot,
                    onMerge: onMerge,
                    onCancel: onCancel
                )
                .environment(\.locale, locale)
            }
            .sheet(item: $rollbackContext) { context in
                RebasedMultiRootMergeRollbackView(
                    branchName: context.branchName,
                    targets: context.targets,
                    failures: context.failures,
                    onRollback: { onRollback(context.targets) },
                    onKeep: { onKeep(context) },
                    onDone: onDone
                )
            }
    }
}

/// A Find Merged result is a read-only document, but IntelliJ exposes it from
/// the operation notification after the scan has finished. Persist the
/// document itself so that a semantic "Open Report" action remains useful
/// after Arbor is relaunched, instead of silently starting a different scan.
struct PersistedFindMergedReport: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let projectPath: String
    let targetBranch: String
    let prefix: String
    let report: String
    let createdAt: Date
}

enum FindMergedReportStore {
    static let defaultsKey = "arbor.findMergedReports.v1"
    static let maximumReports = 32

    static func save(
        _ report: PersistedFindMergedReport,
        defaults: UserDefaults = .standard
    ) {
        var reports = loadAll(defaults: defaults)
        reports[report.id] = report
        let retained = reports.values
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumReports)
        let encoded = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(
        id: String,
        defaults: UserDefaults = .standard
    ) -> PersistedFindMergedReport? {
        loadAll(defaults: defaults)[id]
    }

    static func loadAll(
        defaults: UserDefaults
    ) -> [String: PersistedFindMergedReport] {
        guard let data = defaults.data(forKey: defaultsKey),
              let reports = try? JSONDecoder().decode(
                  [String: PersistedFindMergedReport].self,
                  from: data
              ) else {
            return [:]
        }
        return reports
    }
}
