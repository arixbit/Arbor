import SwiftUI
import AppKit
import UniformTypeIdentifiers

func logChangesPatchNotificationID(
    rootPaths: [String],
    reverse: Bool
) -> String {
    let roots = rootPaths
        .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        .sorted()
        .map {
            $0
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
        }
    let scope = roots.isEmpty ? "unknown" : roots.joined(separator: "--")
    return "arbor.log-changes-patch.\(reverse ? "reverse" : "apply").\(scope)"
}
func directPatchNotificationID(rootPath: String) -> String {
    let scope = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.direct-patch.\(scope)"
}
func logApplyRecoveryKey(repositoryPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.log-apply-recovery.v1.\(encoded)"
}
func saveLogApplyRecovery(_ recovery: PersistedLogApplyRecovery) {
    guard let data = try? JSONEncoder().encode(recovery) else { return }
    UserDefaults.standard.set(data, forKey: logApplyRecoveryKey(repositoryPath: recovery.rootPath))
}
func loadLogApplyRecovery(repositoryPath: String) -> PersistedLogApplyRecovery? {
    guard let data = UserDefaults.standard.data(
        forKey: logApplyRecoveryKey(repositoryPath: repositoryPath)
    ) else {
        return nil
    }
    return try? JSONDecoder().decode(PersistedLogApplyRecovery.self, from: data)
}
func pendingLogApplyRecoveries(
    sessionID: String
) -> [PersistedLogApplyRecovery] {
    UserDefaults.standard.dictionaryRepresentation().compactMap { key, value in
        guard key.hasPrefix("arbor.log-apply-recovery.v1."),
              let data = value as? Data,
              let recovery = try? JSONDecoder().decode(
                  PersistedLogApplyRecovery.self,
                  from: data
              ),
              recovery.sessionID == sessionID else {
            return nil
        }
        return recovery
    }.sorted { $0.batchIndex < $1.batchIndex }
}
/// Only the earliest still-pending root may be replayed. This preserves the
/// same ordered compound semantics as the original Log action and prevents a
/// later root from being applied while an earlier root is unresolved.
func logApplyRecoveryCanRun(
    _ recovery: PersistedLogApplyRecovery,
    pending: [PersistedLogApplyRecovery]
) -> Bool {
    pending.sorted { $0.batchIndex < $1.batchIndex }.first == recovery
}
/// Aborting one root cancels the whole ordered Log Revert/Cherry-pick
/// session. The operation is presented as one user action, so later roots
/// must not retain retry markers after the active root has been aborted.
func logApplyRecoveryCancellationTargets(
    current: PersistedLogApplyRecovery?,
    pending: [PersistedLogApplyRecovery]
) -> [PersistedLogApplyRecovery] {
    guard let current else { return [] }
    return pending
        .filter {
            $0.sessionID == current.sessionID
                && $0.operation == current.operation
        }
        .sorted { $0.batchIndex < $1.batchIndex }
}
func logApplyRecoveryActionTitle(
    _ recovery: PersistedLogApplyRecovery
) -> String {
    let operation = switch recovery.operation {
    case .cherryPick: "Cherry-pick"
    case .revert: "Revert"
    }
    guard recovery.preserveLocalChanges else {
        return "Retry \(operation)"
    }
    let policyTitle = GitLocalChangesSavePolicyChoice(rawValue: recovery.savePolicyRaw)?.title
        ?? "Local Changes"
    return "Save and Retry \(operation) (\(policyTitle))"
}
func clearLogApplyRecovery(repositoryPath: String) {
    UserDefaults.standard.removeObject(forKey: logApplyRecoveryKey(repositoryPath: repositoryPath))
}
