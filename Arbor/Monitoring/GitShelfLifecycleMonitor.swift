import CoreServices
import SwiftUI


/// Serializes Shelf lifecycle reads for the same Git root. Listing shelves can
/// finalize pending deletes and purge expired Recently Deleted entries, so two
/// project windows must not perform that file-backed migration concurrently.
private actor GitShelfLifecycleCoordinator {
    static let shared = GitShelfLifecycleCoordinator()

    private var activeRoots: Set<String> = []

    func acquire(rootID: String) -> Bool {
        guard activeRoots.insert(rootID).inserted else { return false }
        return true
    }

    func release(rootID: String) {
        activeRoots.remove(rootID)
    }
}

/// IntelliJ starts Shelf lifecycle maintenance immediately and repeats it
/// daily while the project is open. `nil` means run without an initial delay.
func shelfLifecycleDelaySeconds(firstRun: Bool) -> UInt64? {
    firstRun ? nil : 24 * 60 * 60
}

/// Keeps Shelf lifecycle maintenance independent from the visible Shelf panel.
/// The Rust list APIs perform the same startup convergence and seven-day
/// Recently Deleted cleanup as IntelliJ's ShelveChangesManager; this monitor
/// makes that behavior happen even when the user never opens the Shelf view.
struct GitShelfLifecycleMonitor: View {
    let rootPaths: [String]
    let repositoryID: String

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: repositoryID) {
                await monitor()
            }
    }

    private func monitor() async {
        var firstRun = true
        while !Task.isCancelled {
            if let delay = shelfLifecycleDelaySeconds(firstRun: firstRun) {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            firstRun = false
            guard !Task.isCancelled else { return }

            for rootPath in mergedAutoFetchRootPaths(primary: nil, discovered: rootPaths) {
                guard !Task.isCancelled,
                      let repo = try? openRepository(path: rootPath) else { continue }
                let rootID = repo.gitDir()
                guard await GitShelfLifecycleCoordinator.shared.acquire(rootID: rootID) else {
                    continue
                }
                // Both calls are intentionally retained: shelveList finalizes
                // pending deletes, while shelveDeletedList applies the
                // seven-day Recently Deleted cutoff.
                _ = try? repo.shelveList()
                _ = try? repo.shelveDeletedList()
                await GitShelfLifecycleCoordinator.shared.release(rootID: rootID)
            }
        }
    }
}
