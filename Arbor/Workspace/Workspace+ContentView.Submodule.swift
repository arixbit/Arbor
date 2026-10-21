import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// Capture the detached submodule worktrees that moved during a standalone
/// `git submodule update`. Unlike Update Project, this operation does not move
/// the superproject HEAD, so only initialized submodule roots with a changed
/// HEAD are rollback candidates. The same expected-HEAD guard used by the
/// project updater keeps a later checkout or local change from being clobbered.
nonisolated static func submoduleUpdateRollbackTargets(
    before: [GitRootInfo],
    after: [GitRootInfo]
) -> [PersistedMultiRootUpdateRollbackTarget] {
    let beforeByPath = Dictionary(
        uniqueKeysWithValues: before.map {
            (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0)
        }
    )
    let results = after.map {
        RootOperationResult(
            rootPath: $0.path,
            displayName: $0.displayName,
            success: true,
            skipped: false,
            message: "submodule updated"
        )
    }
    let previousHeads = beforeByPath.reduce(into: [String: String]()) { heads, item in
        if let head = item.value.headId, !head.isEmpty {
            heads[item.key] = head
        }
    }
    let currentHeads = after.reduce(into: [String: String]()) { heads, root in
        if let head = root.headId, !head.isEmpty {
            heads[root.path] = head
        }
    }
    let previousBranches = beforeByPath.reduce(into: [String: String]()) { branches, item in
        branches[item.key] = item.value.headBranch ?? ""
    }
    let submodulePaths = after.filter(\.isSubmodule).map(\.path)
    return updateSessionRollbackTargets(
        previousHeads: previousHeads,
        currentHeads: currentHeads,
        results: results,
        submoduleRootPaths: submodulePaths,
        previousHeadBranches: previousBranches
    )
    .filter { target in
        after.contains { root in
            root.isSubmodule
                && URL(fileURLWithPath: root.path).standardizedFileURL.path == target.rootPath
        }
    }
}

func submoduleUpdateRollbackAction(
    targets: [PersistedMultiRootUpdateRollbackTarget]
) -> FeedbackAction? {
    guard !targets.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .rollbackSubmoduleUpdate,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootUpdateRollbackTargets: targets
    )
    return FeedbackAction(title: "Undo Submodule Update", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

/// Capture only the state that makes a deinitialized submodule reversible.
/// A dirty or otherwise ambiguous module deliberately gets no Undo action.
nonisolated static func submoduleDeinitUndoContext(
    path: String,
    before: [SubmoduleInfo],
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> PersistedSubmoduleUndo? {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "./", with: "", options: [.anchored])
    guard !normalizedPath.isEmpty,
          let module = before.first(where: { $0.path == normalizedPath }),
          module.state == .clean,
          !module.dirty,
          !module.headId.isEmpty else {
        return nil
    }
    return PersistedSubmoduleUndo(
        operation: .deinitialize,
        path: normalizedPath,
        expectedHeadID: module.headId,
        expectedGitmodulesPresent: gitmodulesPresent,
        expectedGitmodulesContents: gitmodulesContents
    )
}

/// Capture the clean pre-add boundary. An already occupied path is excluded
/// because its exact filesystem shape is not represented in the durable
/// undo payload and must never be guessed on restore.
nonisolated static func submoduleAddUndoSeed(
    path: String,
    before: [SubmoduleInfo],
    parentHeadID: String?,
    gitmodulesPresent: Bool,
    gitmodulesContents: String?,
    pathExists: Bool
) -> SubmoduleAddUndoSeed? {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "./", with: "", options: [.anchored])
    guard !normalizedPath.isEmpty,
          !pathExists,
          !before.contains(where: { $0.path == normalizedPath }),
          let parentHeadID,
          !parentHeadID.isEmpty else {
        return nil
    }
    return SubmoduleAddUndoSeed(
        path: normalizedPath,
        parentHeadID: parentHeadID,
        gitmodulesPresent: gitmodulesPresent,
        gitmodulesContents: gitmodulesContents
    )
}

nonisolated static func submoduleAddUndoContext(
    _ seed: SubmoduleAddUndoSeed,
    module: SubmoduleInfo,
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> PersistedSubmoduleUndo? {
    guard module.path == seed.path,
          module.state == .clean,
          !module.dirty,
          !module.headId.isEmpty,
          gitmodulesPresent,
          gitmodulesContents != nil else {
        return nil
    }
    return PersistedSubmoduleUndo(
        operation: .add,
        path: seed.path,
        expectedHeadID: module.headId,
        expectedGitmodulesPresent: gitmodulesPresent,
        expectedGitmodulesContents: gitmodulesContents,
        expectedParentHeadID: seed.parentHeadID,
        restoreGitmodulesPresent: seed.gitmodulesPresent,
        restoreGitmodulesContents: seed.gitmodulesContents
    )
}

/// Capture the clean pre-remove boundary. Existing edits in either the
/// worktree or index are intentionally excluded: restoring a removed
/// submodule must not silently replace a user's staged `.gitmodules` or
/// gitlink change.
nonisolated static func submoduleRemoveUndoSeed(
    repo: Repository,
    path: String,
    before: [SubmoduleInfo],
    parentHeadID: String?,
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> SubmoduleRemoveUndoSeed? {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "./", with: "", options: [.anchored])
    guard !normalizedPath.isEmpty,
          let module = before.first(where: { $0.path == normalizedPath }),
          module.state == .clean,
          !module.dirty,
          !module.headId.isEmpty,
          let parentHeadID,
          !parentHeadID.isEmpty,
          gitmodulesPresent,
          gitmodulesContents != nil else {
        return nil
    }
    guard (try? repo.submoduleWorktreeHasUntrackedOrIgnoredFiles(path: normalizedPath)) == false else {
        return nil
    }
    let workingTreeClean = (try? repo.runGitCommand(
        command: "diff",
        args: ["--quiet", "--", ".gitmodules"]
    ).exitCode) == 0
    let indexClean = (try? repo.runGitCommand(
        command: "diff",
        args: ["--cached", "--quiet", "--", ".gitmodules"]
    ).exitCode) == 0
    guard workingTreeClean, indexClean else { return nil }
    return SubmoduleRemoveUndoSeed(
        path: normalizedPath,
        parentHeadID: parentHeadID,
        gitlinkID: module.headId,
        gitmodulesPresent: gitmodulesPresent,
        gitmodulesContents: gitmodulesContents
    )
}

nonisolated static func submoduleRemoveUndoContextAfterRemove(
    _ seed: SubmoduleRemoveUndoSeed,
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> PersistedSubmoduleUndo? {
    guard gitmodulesPresent, gitmodulesContents != nil else { return nil }
    return PersistedSubmoduleUndo(
        operation: .remove,
        path: seed.path,
        expectedHeadID: seed.gitlinkID,
        expectedGitmodulesPresent: gitmodulesPresent,
        expectedGitmodulesContents: gitmodulesContents,
        expectedParentHeadID: seed.parentHeadID,
        restoreGitmodulesPresent: seed.gitmodulesPresent,
        restoreGitmodulesContents: seed.gitmodulesContents
    )
}

/// Validate that the deinit command produced the exact expected intermediate
/// state before exposing Undo. This prevents a later index or .gitmodules edit
/// from being mistaken for the original operation's result.
nonisolated static func submoduleDeinitUndoTargetAfterDeinit(
    _ context: PersistedSubmoduleUndo,
    modules: [SubmoduleInfo],
    gitmodulesPresent: Bool,
    gitmodulesContents: String?
) -> PersistedSubmoduleUndo? {
    guard context.operation == .deinitialize,
          let module = modules.first(where: { $0.path == context.path }),
          module.state == .uninitialized,
          !module.dirty,
          module.headId == context.expectedHeadID,
          gitmodulesPresent == context.expectedGitmodulesPresent,
          gitmodulesContents == context.expectedGitmodulesContents else {
        return nil
    }
    return context
}

func submoduleUpdateRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "git.submodule.update.rollback.\(stableProject)"
}

/// Open the same root-scoped Push dialog for an initialized submodule. A
/// submodule is a real Git repository with its own remotes and upstream; it
/// must not inherit the superproject's push target or branch state.
func beginSubmodulePushDialog(_ path: String) {
    guard let submodulePath = submoduleRootPath(path) else { return }
    beginMultiRootPushDialog(rootPath: submodulePath, branch: "")
}

/// Open RemoteConfigDialog for the nested repository itself. The parent
/// repository's remote list and refspecs are unrelated to a submodule.
func beginSubmoduleRemoteConfig(_ path: String) {
    guard let submodulePath = submoduleRootPath(path) else { return }
    beginMultiRootRemoteConfig(rootPath: submodulePath)
}

func submoduleRootPath(_ path: String) -> String? {
    guard let projectPath = projectWorkspace.path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: projectPath)
        .appendingPathComponent(path)
        .standardizedFileURL
        .path
}

struct SubmoduleGitmodulesSnapshot: Equatable, Sendable {
    let present: Bool
    let contents: String?
}

struct SubmoduleRemoveUndoSeed: Sendable {
    let path: String
    let parentHeadID: String
    let gitlinkID: String
    let gitmodulesPresent: Bool
    let gitmodulesContents: String?
}

struct SubmoduleAddUndoSeed: Sendable {
    let path: String
    let parentHeadID: String
    let gitmodulesPresent: Bool
    let gitmodulesContents: String?
}

nonisolated static func submoduleGitmodulesSnapshot(rootPath: String) throws -> SubmoduleGitmodulesSnapshot {
    let url = URL(fileURLWithPath: rootPath).appendingPathComponent(".gitmodules")
    guard FileManager.default.fileExists(atPath: url.path) else {
        return SubmoduleGitmodulesSnapshot(present: false, contents: nil)
    }
    return SubmoduleGitmodulesSnapshot(
        present: true,
        contents: try String(contentsOf: url, encoding: .utf8)
    )
}

nonisolated static func ensureSubmoduleUndoWorktreeIsEmpty(
    rootPath: String,
    path: String
) throws {
    let url = URL(fileURLWithPath: rootPath).appendingPathComponent(path, isDirectory: true)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return
    }
    guard isDirectory.boolValue else {
        throw NSError(
            domain: "Arbor.SubmoduleUndo",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The submodule path is occupied by a file."]
        )
    }
    guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
        throw NSError(
            domain: "Arbor.SubmoduleUndo",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The submodule worktree contains files created after deinit."]
        )
    }
}

func submoduleOperationTitle(_ retry: PersistedSubmoduleRetry) -> String {
    switch retry.operation {
    case .add: "Add submodule"
    case .update: retry.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "Update submodule"
            : "Update submodules"
    case .sync: "Sync submodules"
    case .deinitialize: "Deinit submodule"
    case .remove: "Remove submodule"
    case .setBranch: "Set submodule branch"
    }
}

func submoduleOperationSuccessTitle(_ retry: PersistedSubmoduleRetry) -> String {
    switch retry.operation {
    case .add: "Submodule added"
    case .update: retry.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "Submodule updated"
            : "Submodules updated"
    case .sync: "Submodules synchronized"
    case .deinitialize: "Submodule deinitialized"
    case .remove: "Submodule removed"
    case .setBranch: "Submodule branch set"
    }
}

func submoduleOperationDetail(_ retry: PersistedSubmoduleRetry) -> String? {
    switch retry.operation {
    case .add:
        return retry.path
    case .update:
        return [
            retry.path.map { "path=\($0)" },
            retry.initFlag.map { "init=\($0)" },
            retry.recursive.map { "recursive=\($0)" },
            retry.remote.map { "remote=\($0)" }
        ].compactMap { $0 }.joined(separator: ", ")
    case .sync:
        return nil
    case .deinitialize, .remove:
        return retry.path
    case .setBranch:
        guard let path = retry.path, let branch = retry.branch else { return nil }
        return "\(path) → \(branch)"
    }
}

func submoduleNotificationID(
    _ retry: PersistedSubmoduleRetry,
    rootPath: String
) -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let options = [
        retry.initFlag.map { "init=\($0)" },
        retry.recursive.map { "recursive=\($0)" },
        retry.remote.map { "remote=\($0)" },
        retry.force.map { "force=\($0)" }
    ].compactMap { $0 }.joined(separator: ",")
    return [
        "git.submodule",
        retry.operation.rawValue,
        arborNotificationIDComponent(URL(fileURLWithPath: projectPath).standardizedFileURL.path),
        arborNotificationIDComponent(URL(fileURLWithPath: rootPath).standardizedFileURL.path),
        arborNotificationIDComponent(retry.path ?? "all"),
        arborNotificationIDComponent(retry.branch ?? ""),
        arborNotificationIDComponent(options)
    ].joined(separator: ".")
}

func submoduleRetryRequest(
    _ retry: PersistedSubmoduleRetry,
    rootPath: String
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .retrySubmoduleOperation,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        submoduleRetry: retry
    )
}

func submoduleRetryFeedbackAction(
    _ retry: PersistedSubmoduleRetry,
    rootPath: String
) -> FeedbackAction {
    let request = submoduleRetryRequest(retry, rootPath: rootPath)
    let title: String = switch retry.operation {
    case .add: "Retry Add Submodule"
    case .update: "Retry Submodule Update"
    case .sync: "Retry Submodule Sync"
    case .deinitialize: "Retry Submodule Deinit"
    case .remove: "Retry Remove Submodule"
    case .setBranch: "Retry Set Submodule Branch"
    }
    let initOption = retry.initFlag.map { String($0) } ?? ""
    let recursiveOption = retry.recursive.map { String($0) } ?? ""
    let remoteOption = retry.remote.map { String($0) } ?? ""
    let forceOption = retry.force.map { String($0) } ?? ""
    let identity: String = [
        retry.operation.rawValue,
        retry.path ?? "all",
        retry.branch ?? "",
        retry.url ?? "",
        initOption,
        recursiveOption,
        remoteOption,
        forceOption
    ].joined(separator: "|")
    return FeedbackAction(
        id: "retry-submodule:\(identity)",
        title: title,
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

func submoduleUndoNotificationID(
    _ context: PersistedSubmoduleUndo,
    rootPath: String
) -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    return [
        "git.submodule.undo",
        context.operation.rawValue,
        arborNotificationIDComponent(URL(fileURLWithPath: projectPath).standardizedFileURL.path),
        arborNotificationIDComponent(URL(fileURLWithPath: rootPath).standardizedFileURL.path),
        arborNotificationIDComponent(context.path),
        arborNotificationIDComponent(context.expectedHeadID)
    ].joined(separator: ".")
}

func submoduleUndoRequest(
    _ context: PersistedSubmoduleUndo,
    rootPath: String
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .undoSubmoduleOperation,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        submoduleUndo: context
    )
}

func submoduleUndoFeedbackAction(
    _ context: PersistedSubmoduleUndo,
    rootPath: String
) -> FeedbackAction {
    let request = submoduleUndoRequest(context, rootPath: rootPath)
    let isAdd = context.operation == .add
    let isRemove = context.operation == .remove
    return FeedbackAction(
        id: "undo-submodule-\(context.operation.rawValue):\(context.path):\(context.expectedHeadID)",
        title: isAdd
            ? "Undo Submodule Add"
            : (isRemove ? "Undo Submodule Remove" : "Undo Submodule Deinit"),
        semanticAction: request
    ) {
        handleVCSActionRequest(request)
    }
}

/// Undo an add, deinit, or clean remove only after checking every piece of state
/// that the operation could overwrite. The nested update is issued by the
/// parent repository so the gitlink remains authoritative, matching
/// IntelliJ's submodule model.
func undoSubmoduleOperation(
    _ context: PersistedSubmoduleUndo,
    rootPath: String
) {
    guard context.operation == .add
        || context.operation == .deinitialize
        || context.operation == .remove else { return }
    let isAdd = context.operation == .add
    let isRemove = context.operation == .remove
    let notificationID = submoduleUndoNotificationID(context, rootPath: rootPath)
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation(
        isAdd
            ? "Undo Submodule Add"
            : (isRemove ? "Undo Submodule Remove" : "Undo Submodule Deinit"),
        cancelHandle: cancel,
        notificationID: notificationID
    )

    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let currentModules = try rootRepo.submoduleList()
            let currentGitmodules = try ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath)
            if isRemove {
                guard let expectedParentHeadID = context.expectedParentHeadID,
                      let restoreGitmodulesPresent = context.restoreGitmodulesPresent else {
                    throw NSError(
                        domain: "Arbor.SubmoduleUndo",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "The remove undo context is incomplete."]
                    )
                }
                try rootRepo.submoduleRemoveUndoWithAuthAndCancel(
                    target: SubmoduleRemoveUndoTarget(
                        path: context.path,
                        expectedParentHeadId: expectedParentHeadID,
                        restoreGitlinkId: context.expectedHeadID,
                        expectedGitmodulesPresent: context.expectedGitmodulesPresent,
                        expectedGitmodulesContents: context.expectedGitmodulesContents,
                        restoreGitmodulesPresent: restoreGitmodulesPresent,
                        restoreGitmodulesContents: context.restoreGitmodulesContents
                    ),
                    broker: broker,
                    cancel: cancel
                )
            } else if isAdd {
                guard let currentModule = currentModules.first(where: { $0.path == context.path }),
                      currentModule.state == .clean,
                      !currentModule.dirty,
                      currentModule.headId == context.expectedHeadID,
                      let expectedParentHeadID = context.expectedParentHeadID,
                      currentGitmodules.present == context.expectedGitmodulesPresent,
                      currentGitmodules.contents == context.expectedGitmodulesContents else {
                    throw NSError(
                        domain: "Arbor.SubmoduleUndo",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "The submodule state changed after add; Undo was refused."]
                    )
                }
                guard (try rootRepo.submoduleWorktreeHasUntrackedOrIgnoredFiles(path: context.path)) == false else {
                    throw NSError(
                        domain: "Arbor.SubmoduleUndo",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "The nested worktree has changes; Undo was refused."]
                    )
                }
                try rootRepo.submoduleAddUndoWithAuthAndCancel(
                    target: SubmoduleAddUndoTarget(
                        path: context.path,
                        expectedParentHeadId: expectedParentHeadID,
                        expectedSubmoduleHeadId: context.expectedHeadID,
                        expectedGitmodulesPresent: context.expectedGitmodulesPresent,
                        expectedGitmodulesContents: context.expectedGitmodulesContents,
                        restoreGitmodulesPresent: context.restoreGitmodulesPresent ?? false,
                        restoreGitmodulesContents: context.restoreGitmodulesContents
                    ),
                    broker: broker,
                    cancel: cancel
                )
            } else {
                guard let currentModule = currentModules.first(where: { $0.path == context.path }),
                      currentModule.state == .uninitialized,
                      !currentModule.dirty,
                      currentModule.headId == context.expectedHeadID,
                      currentGitmodules.present == context.expectedGitmodulesPresent,
                      currentGitmodules.contents == context.expectedGitmodulesContents else {
                    throw NSError(
                        domain: "Arbor.SubmoduleUndo",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "The submodule state changed after deinit; Undo was refused."]
                    )
                }
                try ContentView.ensureSubmoduleUndoWorktreeIsEmpty(
                    rootPath: rootPath,
                    path: context.path
                )
                try rootRepo.submoduleUpdatePathWithAuthAndCancel(
                    path: context.path,
                    recursive: false,
                    broker: broker,
                    cancel: cancel
                )
            }
            let restoredModules = try rootRepo.submoduleList()
            let restoredGitmodules = try ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath)
            let restoredModule = restoredModules.first(where: { $0.path == context.path })
            if isAdd {
                guard restoredModule == nil,
                      restoredGitmodules.present == (context.restoreGitmodulesPresent ?? false),
                      restoredGitmodules.contents == context.restoreGitmodulesContents else {
                    throw NSError(
                        domain: "Arbor.SubmoduleUndo",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "The submodule add was not undone to the expected state."]
                    )
                }
            } else {
                guard let restoredModule,
                      restoredModule.state == .clean,
                      !restoredModule.dirty,
                      restoredModule.headId == context.expectedHeadID,
                      restoredGitmodules.present == (isRemove ? context.restoreGitmodulesPresent : context.expectedGitmodulesPresent),
                      restoredGitmodules.contents == (isRemove ? context.restoreGitmodulesContents : context.expectedGitmodulesContents) else {
                    throw NSError(
                        domain: "Arbor.SubmoduleUndo",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "The submodule was not restored to the expected clean commit."]
                    )
                }
            }
            await MainActor.run {
                self.submoduleWorkspace.submodules = restoredModules
                self.submoduleWorkspace.feedback = isAdd
                    ? "Submodule add undone"
                    : (isRemove ? "Submodule removal undone" : "Submodule deinitialized state restored")
                self.feedbackCenter.success(
                    isAdd
                        ? "Submodule add undone"
                        : (isRemove ? "Submodule remove undone" : "Submodule deinit undone"),
                    detail: context.path,
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.submoduleWorkspace.feedback = errorMessage(error)
                let retryAction = self.submoduleUndoFeedbackAction(context, rootPath: rootPath)
                if let engineError = error as? EngineError, case .Cancelled = engineError {
                    self.feedbackCenter.warning(
                        isAdd
                            ? "Undo Submodule Add canceled"
                            : (isRemove ? "Undo Submodule Remove canceled" : "Undo Submodule Deinit canceled"),
                        detail: context.path,
                        additionalActions: [retryAction],
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        isAdd
                            ? "Undo Submodule Add failed"
                            : (isRemove ? "Undo Submodule Remove failed" : "Undo Submodule Deinit failed"),
                        detail: errorMessage(error),
                        nextStep: "检查子模块状态后重试；Arbor 不会覆盖现有文件。",
                        additionalActions: [retryAction],
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                }
            }
        }
    }
}

func runSubmoduleOperation(_ retry: PersistedSubmoduleRetry) {
    guard let repo else { return }
    let rootPath = repo.workdir() ?? ""
    let title = submoduleOperationTitle(retry)
    let notificationID = submoduleNotificationID(retry, rootPath: rootPath)
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let savePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation(
        title,
        cancelHandle: retry.operation == .setBranch ? nil : cancel,
        notificationID: notificationID
    )
    let beforeRoots = retry.operation == .update
        ? ((try? discoverGitRoots(scanRoot: rootPath, maxDepth: nil)) ?? [])
        : []
    let beforeDeinitUndo: PersistedSubmoduleUndo? = {
        guard retry.operation == .deinitialize,
              let path = retry.path,
              let modules = try? repo.submoduleList(),
              let snapshot = try? ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath) else {
            return nil
        }
        return ContentView.submoduleDeinitUndoContext(
            path: path,
            before: modules,
            gitmodulesPresent: snapshot.present,
            gitmodulesContents: snapshot.contents
        )
    }()
    let beforeAddUndo: SubmoduleAddUndoSeed? = {
        guard retry.operation == .add,
              let path = retry.path,
              let modules = try? repo.submoduleList(),
              let snapshot = try? ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath) else {
            return nil
        }
        let pathURL = URL(fileURLWithPath: rootPath).appendingPathComponent(path, isDirectory: true)
        return ContentView.submoduleAddUndoSeed(
            path: path,
            before: modules,
            parentHeadID: repo.headCommitId(),
            gitmodulesPresent: snapshot.present,
            gitmodulesContents: snapshot.contents,
            pathExists: FileManager.default.fileExists(atPath: pathURL.path)
        )
    }()
    let beforeRemoveUndo: SubmoduleRemoveUndoSeed? = {
        guard retry.operation == .remove,
              let path = retry.path,
              let modules = try? repo.submoduleList(),
              let snapshot = try? ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath) else {
            return nil
        }
        return ContentView.submoduleRemoveUndoSeed(
            repo: repo,
            path: path,
            before: modules,
            parentHeadID: repo.headCommitId(),
            gitmodulesPresent: snapshot.present,
            gitmodulesContents: snapshot.contents
        )
    }()

    Task.detached(priority: .userInitiated) {
        do {
            switch retry.operation {
            case .add:
                guard let url = retry.url, let path = retry.path else {
                    throw EngineError.GitOperation(message: "submodule add retry is missing URL or path")
                }
                try repo.submoduleAddWithAuthAndCancel(url: url, path: path, broker: broker, cancel: cancel)
            case .update:
                if let path = retry.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    _ = try runSubmoduleUpdateWithPolicy(
                        parentPath: rootPath,
                        path: path,
                        recursive: retry.recursive ?? true,
                        broker: broker,
                        cancel: cancel,
                        savePolicy: savePolicy
                    )
                } else {
                    try repo.submoduleUpdateWithOptionsWithAuthAndCancel(
                        init: retry.initFlag ?? true,
                        recursive: retry.recursive ?? false,
                        remote: retry.remote ?? false,
                        broker: broker,
                        cancel: cancel
                    )
                }
            case .sync:
                try repo.submoduleSyncWithAuthAndCancel(broker: broker, cancel: cancel)
            case .deinitialize:
                guard let path = retry.path else {
                    throw EngineError.GitOperation(message: "submodule deinit retry is missing path")
                }
                try repo.submoduleDeinitWithAuthAndCancel(
                    path: path,
                    force: retry.force ?? true,
                    broker: broker,
                    cancel: cancel
                )
            case .remove:
                guard let path = retry.path else {
                    throw EngineError.GitOperation(message: "submodule remove retry is missing path")
                }
                try repo.submoduleRemoveWithAuthAndCancel(path: path, broker: broker, cancel: cancel)
            case .setBranch:
                guard let path = retry.path, let branch = retry.branch else {
                    throw EngineError.GitOperation(message: "submodule branch retry is missing path or branch")
                }
                try repo.submoduleSetBranch(path: path, branch: branch)
            }

            let afterRoots = retry.operation == .update
                ? ((try? discoverGitRoots(scanRoot: rootPath, maxDepth: nil)) ?? [])
                : []
            let modules = (retry.operation == .add || retry.operation == .sync || retry.operation == .remove || retry.operation == .deinitialize)
                ? (try? repo.submoduleList())
                : nil
            let afterAddSnapshot = retry.operation == .add
                ? (try? ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath))
                : nil
            let afterDeinitSnapshot = retry.operation == .deinitialize
                ? (try? ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath))
                : nil
            let afterRemoveSnapshot = retry.operation == .remove
                ? (try? ContentView.submoduleGitmodulesSnapshot(rootPath: rootPath))
                : nil
            await MainActor.run {
                self.submoduleWorkspace.feedback = submoduleOperationSuccessTitle(retry)
                if let modules { self.submoduleWorkspace.submodules = modules }
                if retry.operation == .add {
                    self.submoduleWorkspace.url = ""
                    self.submoduleWorkspace.path = ""
                }
                var actions: [FeedbackAction] = []
                if retry.operation == .update {
                    let targets = ContentView.submoduleUpdateRollbackTargets(before: beforeRoots, after: afterRoots)
                    if let undoAction = self.submoduleUpdateRollbackAction(targets: targets) {
                        actions.append(undoAction)
                    }
                }
                if let beforeAddUndo,
                   let modules,
                   let afterAddSnapshot,
                   let addedModule = modules.first(where: { $0.path == beforeAddUndo.path }),
                   let undoContext = ContentView.submoduleAddUndoContext(
                       beforeAddUndo,
                       module: addedModule,
                       gitmodulesPresent: afterAddSnapshot.present,
                       gitmodulesContents: afterAddSnapshot.contents
                   ) {
                    actions.append(
                        self.submoduleUndoFeedbackAction(
                            undoContext,
                            rootPath: rootPath
                        )
                    )
                }
                if let beforeDeinitUndo,
                   let modules,
                   let afterDeinitSnapshot,
                   let undoContext = ContentView.submoduleDeinitUndoTargetAfterDeinit(
                       beforeDeinitUndo,
                       modules: modules,
                       gitmodulesPresent: afterDeinitSnapshot.present,
                       gitmodulesContents: afterDeinitSnapshot.contents
                   ) {
                    actions.append(
                        self.submoduleUndoFeedbackAction(
                            undoContext,
                            rootPath: rootPath
                        )
                    )
                }
                if let beforeRemoveUndo,
                   let afterRemoveSnapshot,
                   let undoContext = ContentView.submoduleRemoveUndoContextAfterRemove(
                       beforeRemoveUndo,
                       gitmodulesPresent: afterRemoveSnapshot.present,
                       gitmodulesContents: afterRemoveSnapshot.contents
                   ) {
                    actions.append(
                        self.submoduleUndoFeedbackAction(
                            undoContext,
                            rootPath: rootPath
                        )
                    )
                }
                self.feedbackCenter.success(
                    submoduleOperationSuccessTitle(retry),
                    detail: submoduleOperationDetail(retry),
                    additionalActions: actions,
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.submoduleWorkspace.feedback = errorMessage(error)
                let retryAction = self.submoduleRetryFeedbackAction(retry, rootPath: rootPath)
                let restoreAction = retry.operation == .update
                    ? self.submoduleUpdateRestoreAction(repo: repo, rootPath: rootPath)
                    : nil
                let actions = [retryAction] + [restoreAction].compactMap { $0 }
                if let engineError = error as? EngineError, case .Cancelled = engineError {
                    self.feedbackCenter.warning(
                        "\(title) canceled",
                        detail: submoduleOperationDetail(retry),
                        additionalActions: actions,
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                } else {
                    self.feedbackCenter.error(
                        "\(title) failed",
                        detail: errorMessage(error),
                        nextStep: restoreAction == nil
                            ? "检查子模块状态后重试。"
                            : "先 Resolve local changes，再重试子模块 Update。",
                        additionalActions: actions,
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                }
            }
        }
    }
}

func submoduleAdd() {
    guard !submoduleWorkspace.url.trimmingCharacters(in: .whitespaces).isEmpty,
          !submoduleWorkspace.path.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    runSubmoduleOperation(
        PersistedSubmoduleRetry(
            operation: .add,
            url: submoduleWorkspace.url.trimmingCharacters(in: .whitespacesAndNewlines),
            path: submoduleWorkspace.path.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    )
}

func submoduleUpdate() {
    runSubmoduleOperation(
        PersistedSubmoduleRetry(operation: .update, initFlag: true, recursive: true, remote: false)
    )
}

/// Update one initialized submodule from its parent, matching IntelliJ's
/// path-scoped `GitSubmoduleUpdater` command. Dirty submodule worktrees are
/// preserved with the configured stash/Shelf policy by the Rust engine.
func submoduleUpdatePath(_ path: String) {
    let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    runSubmoduleOperation(
        PersistedSubmoduleRetry(
            operation: .update,
            path: normalized,
            initFlag: false,
            recursive: true,
            remote: false
        )
    )
}

func submoduleSync() {
    runSubmoduleOperation(PersistedSubmoduleRetry(operation: .sync))
}

/// 在嵌套子模块仓库中打开提交日志；父仓库的 gitlink 只代表固定提交，不是日志数据源。
func openSubmoduleLog(_ path: String) {
    guard let repo else { return }
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return }

    submoduleWorkspace.logPath = path
    submoduleWorkspace.logEntries = []
    submoduleWorkspace.logError = nil
    submoduleWorkspace.showLog = true
    Task.detached(priority: .userInitiated) {
        do {
            let commits = try repo.submoduleLog(path: path, limit: 200)
            await MainActor.run {
                guard self.submoduleWorkspace.showLog, self.submoduleWorkspace.logPath == path else { return }
                self.submoduleWorkspace.logEntries = commits
            }
        } catch {
            await MainActor.run {
                guard self.submoduleWorkspace.showLog, self.submoduleWorkspace.logPath == path else { return }
                self.submoduleWorkspace.logError = errorMessage(error)
            }
        }
    }
}

/// Phase 5：子模块更新（init/recursive/--remote 选项）。
func submoduleUpdateWithOptions(_ initFlag: Bool, _ recursive: Bool, _ remote: Bool) {
    runSubmoduleOperation(
        PersistedSubmoduleRetry(
            operation: .update,
            initFlag: initFlag,
            recursive: recursive,
            remote: remote
        )
    )
}

/// Phase 5：反初始化子模块。
func submoduleDeinit(_ path: String, force: Bool) {
    runSubmoduleOperation(
        PersistedSubmoduleRetry(operation: .deinitialize, path: path, force: force)
    )
}

/// Phase 5：配置子模块跟踪分支。
func submoduleSetBranch(_ path: String, _ branch: String) {
    guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    runSubmoduleOperation(
        PersistedSubmoduleRetry(
            operation: .setBranch,
            path: path,
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    )
}

func submoduleRemove(_ path: String) {
    let alert = NSAlert()
    alert.messageText = "Remove submodule?"
    alert.informativeText = "This removes \(path) from .gitmodules, the index and the worktree."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    runSubmoduleOperation(
        PersistedSubmoduleRetry(
            operation: .remove,
            path: path.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    )
}

}
