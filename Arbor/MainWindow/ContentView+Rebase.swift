import SwiftUI
import AppKit

extension ContentView {

    var rebaseRepositories: [GitRootInfo] {
        multiRootWorkspace.roots.count > 1 ? multiRootWorkspace.roots : []
    }

    var rebaseBranchOptions: [BranchInfo] {
        guard let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
            $0.rootPath == rebaseWorkspace.rootPath
        }) else {
            return branchWorkspace.branches
        }
        return snapshot.branches
    }

    var rebaseTodoSheet: some View {
        Group {
            if let repo {
                RebaseTodoEditorView(
                    repo: repo,
                    onto: rebaseWorkspace.todoOnto,
                    items: $rebaseWorkspace.todoItems,
                    preserveMerges: rebaseWorkspace.todoPreserveMerges,
                    root: rebaseWorkspace.todoRoot,
                    onStart: startTodoRebase,
                    onOpenRawTodo: prepareRawRebaseTodoEditor,
                    onCancel: { rebaseWorkspace.showTodoEditor = false }
                )
            }
        }
        .environment(\.locale, appLocale)
    }

    var rebaseRawTodoSheet: some View {
        RawRebaseTodoEditorView(
            onto: rebaseWorkspace.todoOnto,
            text: $rebaseWorkspace.rawTodoText,
            preserveMerges: rebaseWorkspace.todoPreserveMerges,
            root: rebaseWorkspace.todoRoot,
            onStart: startRawTodoRebase,
            onCancel: {
                rebaseWorkspace.showRawTodoEditor = false
                rebaseWorkspace.rawTodoText = ""
            }
        )
        .environment(\.locale, appLocale)
    }

    func loadRebaseDialogSettings(for projectPath: String?) {
        let settings = GitRebaseDialogSettingsStore.load(for: projectPath)
        rebaseWorkspace.onto = settings.onto
        rebaseWorkspace.interactive = settings.interactive
        rebaseWorkspace.preserveMerges = settings.preserveMerges
        rebaseWorkspace.autoSquash = settings.autoSquash
        rebaseWorkspace.keepEmpty = settings.keepEmpty
        rebaseWorkspace.updateRefs = settings.updateRefs
        rebaseWorkspace.root = settings.root
    }

    func saveRebaseDialogSettings() {
        GitRebaseDialogSettingsStore.save(
            GitRebaseDialogSettings(
                onto: rebaseWorkspace.onto,
                interactive: rebaseWorkspace.interactive,
                preserveMerges: rebaseWorkspace.preserveMerges,
                autoSquash: rebaseWorkspace.autoSquash,
                keepEmpty: rebaseWorkspace.keepEmpty,
                updateRefs: rebaseWorkspace.updateRefs,
                root: rebaseWorkspace.root
            ),
            for: projectWorkspace.path
        )
    }

    func openRebaseDialog(_ branch: String?) {
        guard operationRecovery.operation?.kind == nil,
              isArborVCSActionVisible(.rebase, in: vcsActionContext),
              isArborVCSActionEnabled(.rebase, in: vcsActionContext) else { return }
        loadRebaseDialogSettings(for: projectWorkspace.path)
        if let branch { rebaseWorkspace.onto = branch }
        rebaseWorkspace.rootPath = repo?.workdir() ?? multiRootWorkspace.roots.first?.path ?? ""
        rebaseWorkspace.branch = rebaseBranchOptions.first(where: { $0.isCurrent })?.name
            ?? rebaseBranchOptions.first?.name
            ?? ""
        rebaseWorkspace.applyToAllRoots = false
        rebaseWorkspace.range = []
        rebaseWorkspace.actions = []
        rebaseWorkspace.feedback = nil
        rebaseWorkspace.showActionDialog = true
    }

    func selectRebaseRepository() {
        let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
            $0.rootPath == rebaseWorkspace.rootPath
        })
        rebaseWorkspace.branch = snapshot?.headBranch
            ?? snapshot?.branches.first(where: { $0.isCurrent })?.name
            ?? snapshot?.branches.first?.name
            ?? ""
        invalidateLoadedRebaseRange()
    }
}
