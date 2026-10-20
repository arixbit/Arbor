import SwiftUI
import AppKit
import UniformTypeIdentifiers

func externalVCSActionNotificationID(repositoryPath: String) -> String {
    let stablePath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.external-vcs-action.\(stablePath)"
}
struct RepositoryExternalVCSActionExecutionError: LocalizedError, Sendable {
    let message: String
    let remainingAction: RepositoryExternalVCSAction

    var errorDescription: String? { message }
}
func runRepositoryExternalVCSActions(
    repo: Repository,
    action: RepositoryExternalVCSAction
) throws -> String {
    var completed: [String] = []
    var remainingAddPaths = action.addPaths
    var remainingStageAddPaths = action.stageAddPaths
    var remainingRemovePaths = action.removePaths
    var remainingForceMoves = action.forceMoves

    func executionError(_ error: Error) -> RepositoryExternalVCSActionExecutionError {
        RepositoryExternalVCSActionExecutionError(
            message: error.localizedDescription,
            remainingAction: RepositoryExternalVCSAction(
                addPaths: remainingAddPaths,
                stageAddPaths: remainingStageAddPaths,
                removePaths: remainingRemovePaths,
                forceMoves: remainingForceMoves
            )
        )
    }

    let addPaths = action.addPaths
    if !addPaths.isEmpty {
        // Rename destinations follow IntelliJ's move/rename path and stage
        // their complete content. Newly created files use the separate
        // empty-blob path below.
        let result: GitCommandResult
        do {
            result = try repo.runGitCommand(
                command: "add",
                args: ["--"] + addPaths
            )
        } catch {
            throw executionError(error)
        }
        guard result.exitCode == 0 else {
            throw executionError(NSError(
                domain: "Arbor.GitVFSListener",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty ? result.stdout : result.stderr
                ]
            ))
        }
        remainingAddPaths.removeAll()
        completed.append("Added \(addPaths.count) file(s)")
    }
    let stageAddPaths = action.stageAddPaths
    if !stageAddPaths.isEmpty {
        // IntelliJ's staging-area VFS listener uses addPathsToIndex: an empty
        // blob is written to the index while the real content stays outside it.
        do {
            try repo.stageEmptyBlobPaths(paths: stageAddPaths)
        } catch {
            throw executionError(error)
        }
        remainingStageAddPaths.removeAll()
        completed.append("Added \(stageAddPaths.count) new file(s) to the staging index")
    }
    let removePaths = action.removePaths
    if !removePaths.isEmpty {
        let result: GitCommandResult
        do {
            result = try repo.runGitCommand(
                command: "rm",
                args: ["--cached", "--ignore-unmatch", "-r", "--"] + removePaths
            )
        } catch {
            throw executionError(error)
        }
        guard result.exitCode == 0 else {
            throw executionError(NSError(
                domain: "Arbor.GitVFSListener",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty ? result.stdout : result.stderr
                ]
            ))
        }
        remainingRemovePaths.removeAll()
        completed.append("Removed \(removePaths.count) file(s) from Git")
    }
    // GitVFSListener performs ordinary add/delete work before case-only force
    // moves. Preserve that ordering for mixed VFS batches.
    if !action.forceMoves.isEmpty {
        for move in action.forceMoves {
            let result: GitCommandResult
            do {
                result = try repo.runGitCommand(
                    command: "mv",
                    args: ["-f", "--", move.oldPath, move.newPath]
                )
            } catch {
                throw executionError(error)
            }
            guard result.exitCode == 0 else {
                throw executionError(NSError(
                    domain: "Arbor.GitVFSListener",
                    code: Int(result.exitCode),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            result.stderr.isEmpty ? result.stdout : result.stderr
                    ]
                ))
            }
            remainingForceMoves.removeFirst()
            completed.append("Moved \(move.oldPath) to \(move.newPath)")
        }
    }
    return completed.joined(separator: "; ")
}
