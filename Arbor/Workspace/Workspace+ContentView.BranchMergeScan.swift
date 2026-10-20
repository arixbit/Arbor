import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

struct BranchMergeScanResult {
    let index: Int
    let root: BranchCleanupRoot
    let repositoryScanned: Bool
    let candidateBranchesChecked: Int
    let mergedBranchesFound: Int
    let error: String?
}

nonisolated func scanBranchMergeRoot(
    _ root: BranchCleanupRoot,
    index: Int,
    target: String,
    prefix: String
) -> BranchMergeScanResult {
    let candidates = root.branches.filter {
        $0.name != target && (prefix.isEmpty || $0.name.hasPrefix(prefix))
    }
    guard root.branches.contains(where: { $0.name == target }) else {
        let error = "target branch '\(target)' was not found"
        return BranchMergeScanResult(
            index: index,
            root: BranchCleanupRoot(
                rootPath: root.rootPath,
                displayName: root.displayName,
                relativePath: root.relativePath,
                branches: root.branches,
                trackingByBranch: root.trackingByBranch,
                mergedBranches: [],
                calculatedTarget: nil,
                calculatedPrefix: nil,
                calculationError: error
            ),
            repositoryScanned: false,
            candidateBranchesChecked: 0,
            mergedBranchesFound: 0,
            error: error
        )
    }

    do {
        let rootRepo = try openRepository(path: root.rootPath)
        let merged = try rootRepo.branchListMergedInto(target: target, prefix: prefix)
        // The engine and the UI both exclude the comparison branch. Keeping
        // this boundary here also protects older engine builds that returned
        // the target itself for an empty prefix.
        let mergedNames = Set(merged.map(\.name).filter { $0 != target })
        return BranchMergeScanResult(
            index: index,
            root: BranchCleanupRoot(
                rootPath: root.rootPath,
                displayName: root.displayName,
                relativePath: root.relativePath,
                branches: root.branches,
                trackingByBranch: root.trackingByBranch,
                mergedBranches: mergedNames,
                calculatedTarget: target,
                calculatedPrefix: prefix,
                calculationError: nil
            ),
            repositoryScanned: true,
            candidateBranchesChecked: candidates.count,
            mergedBranchesFound: mergedNames.count,
            error: nil
        )
    } catch {
        let error = errorMessage(error)
        return BranchMergeScanResult(
            index: index,
            root: BranchCleanupRoot(
                rootPath: root.rootPath,
                displayName: root.displayName,
                relativePath: root.relativePath,
                branches: root.branches,
                trackingByBranch: root.trackingByBranch,
                mergedBranches: [],
                calculatedTarget: nil,
                calculatedPrefix: nil,
                calculationError: error
            ),
            repositoryScanned: true,
            candidateBranchesChecked: candidates.count,
            mergedBranchesFound: 0,
            error: error
        )
    }
}

/// Scan roots concurrently in small batches. IntelliJ bounds its comparison
/// pool to five workers; batching gives the same upper bound while retaining
/// deterministic ordering and a cancellation boundary between batches.
nonisolated func scanBranchMergeRoots(
    _ roots: [BranchCleanupRoot],
    target: String,
    prefix: String
) async -> [BranchMergeScanResult] {
    let batchSize = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 5))
    var results: [BranchMergeScanResult] = []

    for start in stride(from: 0, to: roots.count, by: batchSize) {
        if Task.isCancelled { break }
        let end = min(start + batchSize, roots.count)
        let batch = Array(roots[start..<end])
        let batchResults = await withTaskGroup(of: BranchMergeScanResult?.self) { group in
            for (offset, root) in batch.enumerated() {
                let index = start + offset
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return scanBranchMergeRoot(root, index: index, target: target, prefix: prefix)
                }
            }

            var collected: [BranchMergeScanResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }
        results.append(contentsOf: batchResults)
    }

    return results.sorted { $0.index < $1.index }
}

}
