import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// FindMergedLocalBranchesAction is useful only when at least one repository
/// has a candidate local branch in addition to the target branch.
func isFindMergedBranchesActionEnabled(localBranchCounts: [Int]) -> Bool {
    localBranchCounts.contains { $0 > 1 }
}
/// IntelliJ 的 FindMergedLocalBranchesAction：只读扫描各 Git root，按目标分支
/// 和名称前缀列出已合并的本地分支，并保留仓库边界。
struct FindMergedBranchesDialogView: View {
    let roots: [BranchCleanupRoot]
    let projectName: String
    @Binding var targetBranch: String
    @Binding var prefix: String
    let isRunning: Bool
    let hasCalculated: Bool
    let summary: FindMergedScanSummary?
    let onCalculate: () -> Void
    let onOpenReport: () -> Void
    let onCopy: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    private var normalizedTarget: String {
        targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPrefix: String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMatchingCalculation: Bool {
        summary?.targetBranch == normalizedTarget && summary?.prefix == normalizedPrefix
    }

    private var reportText: String? {
        guard let summary, hasMatchingCalculation else { return nil }
        return findMergedBranchesReportText(
            summary: summary,
            roots: roots,
            projectName: projectName
        )
    }

    private var mergedBranchCount: Int {
        roots.reduce(0) { count, root in
            count + mergedBranches(in: root).count
        }
    }

    private func mergedBranches(in root: BranchCleanupRoot) -> [BranchInfo] {
        mergedBranchNames(
            in: root,
            targetBranch: normalizedTarget,
            prefix: normalizedPrefix
        ).compactMap { name in root.branches.first { $0.name == name } }
    }

    private func rootStatus(for root: BranchCleanupRoot) -> String? {
        guard hasCalculated, root.calculatedTarget == nil else { return nil }
        let title = String(localized: "Calculation unavailable in this repository")
        guard let error = root.calculationError, !error.isEmpty else { return title }
        return "\(title): \(error)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Find Merged Local Branches")
                    .font(.title3.weight(.semibold))
                Spacer()
                if isRunning {
                    Button("Cancel", role: .cancel, action: onCancel)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                }
            }

            HStack(spacing: 10) {
                Text("Target branch")
                TextField("Target branch", text: $targetBranch)
                    .textFieldStyle(.roundedBorder)
                Text("Filter prefix")
                TextField("Filter prefix", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                Button("Find", action: onCalculate)
                    .disabled(normalizedTarget.isEmpty || isRunning)
            }

            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding merged branches…")
                        .foregroundStyle(.secondary)
                } else if hasMatchingCalculation {
                    Text(
                        String(localized: "%@ merged branches found")
                            .replacingOccurrences(of: "%@", with: String(mergedBranchCount))
                    )
                        .foregroundStyle(.secondary)
                } else if hasCalculated {
                    Text("Run Find after changing the target or prefix")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if reportText != nil {
                    Button("Open Report", action: onOpenReport)
                }
                Button("Copy", action: onCopy)
                    .disabled(!hasMatchingCalculation || isRunning)
            }

            if roots.isEmpty {
                if isRunning {
                    ProgressView("Loading repositories…")
                } else if hasCalculated {
                    Text("No repository results are available for this target")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No repositories loaded")
                        .foregroundStyle(.secondary)
                }
            } else {
                List {
                    ForEach(roots) { root in
                        Section {
                        let branches = mergedBranches(in: root)
                            if !hasCalculated {
                                Text("Run Find to calculate merged branches")
                                    .foregroundStyle(.secondary)
                            } else if root.calculatedTarget != normalizedTarget
                                        || root.calculatedPrefix != normalizedPrefix {
                                Text("Run Find after changing the target or prefix")
                                    .foregroundStyle(.secondary)
                            } else if let status = rootStatus(for: root) {
                                Text(status)
                                    .foregroundStyle(.secondary)
                            } else if branches.isEmpty {
                                Text("No merged branches")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(branches, id: \.name) { branch in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.branch")
                                            .foregroundStyle(.green)
                                        Text(branch.name)
                                            .font(.system(.body, design: .monospaced))
                                        Spacer()
                                        Text(branch.shortId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
    }
}
/// IntelliJ opens FindMergedLocalBranches results as a standalone plain-text
/// editor. Keep the document independent from the grouped scan dialog so it
/// can be inspected, selected, edited, or copied after the dialog changes.
struct FindMergedReportEditorView: View {
    let report: String
    @Environment(\.dismiss) private var dismiss
    @State private var document: String

    init(report: String) {
        self.report = report
        _document = State(initialValue: report)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Design.Colors.accent)
                Text("Merged Branches Report")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document, forType: .string)
                }
                Button("Done", role: .cancel) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            TextEditor(text: $document)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
/// Returns stable branch rows for a completed calculation. A root with an
/// error intentionally produces no rows, so a partial result cannot be read
/// as a successful empty result.
func mergedBranchNames(
    in root: BranchCleanupRoot,
    targetBranch: String,
    prefix: String
) -> [String] {
    guard root.calculatedTarget == targetBranch,
          root.calculatedPrefix == prefix else {
        return []
    }
    return root.branches
        .filter {
            $0.name != targetBranch
                && root.mergedBranches.contains($0.name)
                && (prefix.isEmpty || $0.name.hasPrefix(prefix))
        }
        .map(\.name)
        .sorted()
}
/// Builds the plain-text result document used by Find Merged Local Branches.
/// Raw root errors remain visible instead of being reduced to an empty list.
func findMergedBranchesReportText(
    summary: FindMergedScanSummary,
    roots: [BranchCleanupRoot],
    projectName: String
) -> String {
    var lines = [
        "=== Merged local branches into '\(summary.targetBranch)' ==="
    ]
    if !summary.prefix.isEmpty {
        lines.append("Filter prefix: '\(summary.prefix)'")
    }
    if !projectName.isEmpty {
        lines.append("Project: \(projectName)")
    }
    lines.append("")

    var found = 0
    for root in roots.sorted(by: { $0.relativePath < $1.relativePath }) {
        lines.append("Root: \(root.rootPath)")
        if let error = root.calculationError, !error.isEmpty {
            lines.append("  Error: \(error)")
        } else {
            let branches = mergedBranchNames(
                in: root,
                targetBranch: summary.targetBranch,
                prefix: summary.prefix
            )
            found += branches.count
            if branches.isEmpty {
                lines.append("  No merged branches found.")
            } else {
                lines.append(contentsOf: branches.map { "  \($0)" })
            }
        }
        lines.append("")
    }

    lines.append("Summary:")
    lines.append("  Status: \(summary.isCancelled ? "Cancelled" : "Completed")")
    lines.append("  Repositories discovered: \(summary.repositoriesDiscovered)")
    lines.append("  Repositories scanned: \(summary.repositoriesScanned)")
    lines.append("  Candidate branches checked: \(summary.candidateBranchesChecked)")
    lines.append("  Merged branches found: \(found)")
    lines.append("  Errors count: \(summary.errorsCount)")
    lines.append("  Total search time: \(summary.elapsedMilliseconds) ms")
    return lines.joined(separator: "\n") + "\n"
}
