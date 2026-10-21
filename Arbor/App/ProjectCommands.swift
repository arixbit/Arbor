import SwiftUI

struct ProjectCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.arborRepositoryIsShallow) private var isShallowRepository
    @FocusedValue(\.arborVCSActionContext) private var actionContext
    @FocusedValue(\.arborVCSOperationContext) private var operationContext

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("检查更新…") {
                NotificationCenter.default.post(name: .arborCheckForUpdates, object: nil)
            }
            Button("About Arbor") {
                openWindow(id: "about")
            }
        }

        CommandMenu("File") {
            Button("Open Project…") {
                NotificationCenter.default.post(name: .arborOpenProjectPanel, object: nil)
            }
            Button("Initialize Git Repository…") {
                NotificationCenter.default.post(name: .arborInitProjectPanel, object: nil)
            }
            Button("Clone Git Repository…") {
                NotificationCenter.default.post(name: .arborCloneProjectDialog, object: nil)
            }
            Menu("Open Recent Project") {
                let recent = UserDefaults.standard.stringArray(forKey: "lastOpenedPaths") ?? []
                if recent.isEmpty {
                    Text("No Recent Projects")
                } else {
                    ForEach(recent, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            openWindow(value: path)
                        }
                    }
                }
            }
        }
        CommandMenu("VCS") {
            Menu("Git") {
                Button("Search Everywhere…") { postVCS(.searchEverywhere) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(!actionEnabled(.searchEverywhere))
                Button("Quick Git Actions…") { postVCS(.quickActions) }
                    .keyboardShortcut("q", modifiers: [.command, .option])
                    .disabled(!actionEnabled(.quickActions))
                Menu("Tool Windows") {
                    Button("Show Log") { postVCS(.showLog) }
                        .keyboardShortcut("9", modifiers: [.command])
                        .disabled(!actionEnabled(.showLog))
                    Button("Show Log in New Window") { openExternalLogWindow() }
                        .disabled(!actionEnabled(.showExternalLog))
                    Button("Operation Log") { postVCS(.showOperations) }
                        .disabled(!actionEnabled(.showOperations))
                    Button("Git Roots") { postVCS(.showGitRoots) }
                        .disabled(!actionEnabled(.showGitRoots))
                    Button("Git Console") { postVCS(.showGitConsole) }
                        .disabled(!actionEnabled(.showGitConsole))
                }
                Button("Refresh Git State") { postVCS(.refresh) }
                    .disabled(!actionEnabled(.refresh))
                Divider()
                Button("Update Project") { postVCS(.update) }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(!actionEnabled(.update))
                Button("Reset Head…") { postVCS(.reset) }
                    .disabled(!actionEnabled(.reset))
                Button("Reset to Remote Branch…") { postVCS(.resetToRemoteBranch) }
                    .disabled(!actionEnabled(.resetToRemoteBranch))
                Button("Commit…") { postVCS(.commit) }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!actionEnabled(.commit))
                Button("Show Staging Area") { postVCS(.showStagingArea) }
                    .disabled(!actionEnabled(.showStagingArea))
                Button("Commit and Push…") { postVCS(.commitAndPush) }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(!actionEnabled(.commitAndPush))
                Button("Push…") { postVCS(.push) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!actionEnabled(.push))
                Button("Fetch") { postVCS(.fetch) }
                    .disabled(!actionEnabled(.fetch))
                Button("Fetch All") { postVCS(.fetchAll) }
                    .disabled(!actionEnabled(.fetchAll))
                Button("Prune Remote Branches") { postVCS(.fetchPrune) }
                    .disabled(!actionEnabled(.fetchPrune))
                if isShallowRepository == true {
                    Button("Fetch Full History…") { postVCS(.fetchUnshallow) }
                        .disabled(!actionEnabled(.fetchUnshallow))
                }
                Button("Pull…") { postVCS(.pull) }
                    .disabled(!actionEnabled(.pull))
                Divider()
                Menu("Local Changes") {
                    Button("Shelve…") { postVCS(.shelve) }
                        .disabled(!actionEnabled(.shelve))
                    Button("Show Shelf") { postVCS(.showShelf) }
                        .disabled(!actionEnabled(.showShelf))
                    Button("Show Stash") { postVCS(.showStash) }
                        .disabled(!actionEnabled(.showStash))
                    Button("Stash…") { postVCS(.stash) }
                        .disabled(!actionEnabled(.stash))
                    Button("Unstash…") { postVCS(.unstash) }
                        .disabled(!actionEnabled(.unstash))
                    Button("Revert Selected Changes…", role: .destructive) {
                        postVCS(.revertSelectedChanges)
                    }
                    .disabled(!actionEnabled(.revertSelectedChanges))
                }
                Divider()
                Button("Apply Patch…") { postVCS(.applyPatch) }
                    .disabled(!actionEnabled(.applyPatch))
                Button("Apply Patch from Clipboard…") { postVCS(.applyPatchFromClipboard) }
                    .disabled(!actionEnabled(.applyPatchFromClipboard))
                if actionContext?.selectedFileAction != nil {
                    Menu("File Actions") {
                        Button("Checkin Files…") { postVCS(.fileCheckin) }
                            .disabled(!actionEnabled(.fileCheckin))
                        Button("Add") { postVCS(.fileAdd) }
                            .disabled(!actionEnabled(.fileAdd))
                        Divider()
                        Button("Annotate") { postVCS(.fileAnnotate) }
                            .disabled(!actionEnabled(.fileAnnotate))
                        Button("Compare with HEAD") { postVCS(.fileCompareSameVersion) }
                            .disabled(!actionEnabled(.fileCompareSameVersion))
                        Button("Compare with Selected Revision…") {
                            postVCS(.fileCompareSelectedRevision)
                        }
                        .disabled(!actionEnabled(.fileCompareSelectedRevision))
                        Button("Compare with Branch or Tag…") {
                            postVCS(.fileCompareWithBranch)
                        }
                        .disabled(!actionEnabled(.fileCompareWithBranch))
                        Button("Show File History") { postVCS(.fileHistory) }
                            .disabled(!actionEnabled(.fileHistory))
                    }
                }
                if isArborVCSActionVisible(.merge, in: actionContext) {
                    Button("Merge…") { postVCS(.merge) }
                        .disabled(!actionEnabled(.merge))
                }
                if isArborVCSActionVisible(.rebase, in: actionContext) {
                    Button("Rebase…") { postVCS(.rebase) }
                        .disabled(!actionEnabled(.rebase))
                }
                if let operationContext {
                    let actions = gitMainMenuOperationActions(
                        for: operationContext.kind,
                        hasConflicts: operationContext.hasConflicts
                    )
                    if !actions.isEmpty {
                        Divider()
                        if operationContext.kind == .rebase {
                            Menu("Rebase in Progress") {
                                ForEach(actions) { action in
                                    Button(action.title) {
                                        postOperationRecovery(
                                            action.recoveryAction,
                                            rootPath: operationContext.rootPath
                                        )
                                    }
                                }
                            }
                        } else {
                            ForEach(actions) { action in
                                Button(action.title) {
                                    postOperationRecovery(
                                        action.recoveryAction,
                                        rootPath: operationContext.rootPath
                                    )
                                }
                            }
                        }
                    }
                }
                Button("Resolve Conflicts") { postVCS(.resolveConflicts) }
                    .disabled(!actionEnabled(.resolveConflicts))
                if actionContext?.selectedResolvedConflictPath != nil {
                    Button("Revert Resolved") { postVCS(.revertResolved) }
                        .disabled(!actionEnabled(.revertResolved))
                }
                Button("New Branch…") { postVCS(.newBranch) }
                    .disabled(!actionEnabled(.newBranch))
                Button("New Tag…") { postVCS(.newTag) }
                    .disabled(!actionEnabled(.newTag))
                Button("Worktrees…") { postVCS(.worktrees) }
                    .disabled(!actionEnabled(.worktrees))
                Button("Branches…") { postVCS(.branches) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!actionEnabled(.branches))
                Divider()
                Button("Configure Remotes…") { postVCS(.configureRemotes) }
                    .disabled(!actionEnabled(.configureRemotes))
                Button("Git LFS…") { postVCS(.gitLfs) }
                    .disabled(!actionEnabled(.gitLfs))
                Button("Git Hooks…") { postVCS(.gitHooks) }
                    .disabled(!actionEnabled(.gitHooks))
                Button("Clone Git Repository…") {
                    NotificationCenter.default.post(name: .arborCloneProjectDialog, object: nil)
                }
            }
        }
        CommandGroup(after: .appSettings) {
            SettingsLink {
                Text("Language…")
            }
        }
    }

    private func postVCS(_ action: ArborVCSAction) {
        NotificationCenter.default.post(name: .arborVCSAction, object: action.rawValue)
    }

    private func postOperationRecovery(
        _ action: ArborVCSActionRequest.OperationRecoveryAction,
        rootPath: String
    ) {
        NotificationCenter.default.post(
            name: .arborVCSAction,
            object: ArborVCSActionRequest(
                kind: .operationRecovery,
                projectPath: actionContext?.projectPath,
                rootPath: rootPath,
                shelfName: "",
                operationRecoveryAction: action
            )
        )
    }

    private func actionEnabled(_ action: ArborVCSAction) -> Bool {
        isArborVCSActionEnabled(action, in: actionContext)
    }

    private func openExternalLogWindow() {
        guard let projectPath = actionContext?.projectPath else { return }
        guard let request = chooseExternalLogWindowRequest(for: projectPath) else { return }
        openWindow(id: "git-log", value: request)
    }
}
