# 界面对账得出的缺口清单

由 `scripts/ui-triage.py` 生成，**不要手改**；人给的结论在
`scripts/ui-gaps-baseline.txt` 里。

重新生成：`./scripts/ui-parity.sh --reference &&
python3 scripts/ui-triage.py --write-doc docs/ui-gaps.md`

判定方法：把「参考有、Arbor 缺」的每个名字回查 Arbor 的源码和本地化表。
源码里有 → 功能在做、只是叫法或入口位置不同；没有 → 才进下面的清单，
而且每一项都必须在 baseline 里给出结论，缺结论时脚本会失败。

## 待补

| 缺口 | 出现界面 | 说明 |
| --- | --- | --- |

## 已判定：不复刻或已有等价入口

| 结论 | 缺口 | 界面 | 理由 |
| --- | --- | --- | --- |
| out-of-scope | Enable Git Log Indexing | commit, log | IntelliJ 的日志索引是 IDE 侧能力，Arbor 用 git log 直接读。 |
| naming | Project: visual-fixture, menu | commit, log | Arbor 顶栏的项目控件也是 Menu（menubutton），只是 label 直接显示项目名，参考拼成「Project: 名字, menu」。 |
| naming | beta | branches | 同上：参考的分支树把 "bugfix/beta" 拆成父目录和叶子两行。 |
| naming | bugfix | branches | 参考把分支名按目录拆成两段显示（bugfix / beta），Arbor 显示完整分支名，比对时各自成一条。 |
| design-difference | main, menu | commit, log | Arbor 的顶栏分支控件是 popover（branches-popover），参考是菜单。弹层里带搜索/对比/标签/贮藏/工作树，换成 Menu 装不下，所以保留 popover；已补 ⌄ 下拉提示和 accessibilityHint，让辅助技术知道它打开的是一个列表。 |

## 附录：源码里有，只是叫法或入口位置不同

这些不是缺口。要压掉对账噪声，把它们写进 `scripts/parity-aliases.tsv`。

- `branches` statictext `Checkout Tag or Revision…` → `Arbor/Dialogs/Dialogs+BranchActions.swift`
- `branches` statictext `Commit…` → `Arbor/LogGraphView.swift`
- `branches` button `Fetch` → `Arbor/PullDialogView.swift`
- `branches` statictext `Local` → `Arbor/AboutView.swift`
- `branches` statictext `New Branch…` → `Arbor/LogGraphView.swift`
- `branches` statictext `Recent` → `Arbor/ArborApp.swift`
- `branches` textfield `Search` → `Arbor/FileReferenceComparisonView.swift`
- `branches` button `Settings` → `Arbor/ArborApp.swift`
- `branches` statictext `Tags` → `Arbor/LogGraphView.swift`
- `branches` statictext `alpha` → `Arbor/GitHubOAuthFlow.swift`
- `branches` statictext `feature` → `Arbor/Dialogs/Dialogs+Rebase.swift`
- `branches` statictext `main` → `Arbor/AboutView.swift`
- `commit` menu `Branch:` → `Arbor/PullDialogView.swift`
- `commit` button `Cherry-Pick` → `Arbor/LogGraphView.swift`
- `commit` button `Collapse All` → `Arbor/Panels/Panels+Core.swift`
- `commit` statictext `Commit` → `Arbor/PullDialogView.swift`
- `commit` textview `Commit Message` → `Arbor/LogGraphView.swift`
- `commit` menu `Date:` → `Arbor/LogGraphView.swift`
- `commit` button `Expand All` → `Arbor/LogGraphView.swift`
- `commit` button `Git` → `Arbor/AboutView.swift`
- `commit` button `Graph Options` → `Arbor/Workspace/Workspace+ContentView.Log.swift`
- `commit` button `Hide` → `Arbor/HostingProvider.swift`
- `commit` button `Open New Git Log Tab` → `Arbor/Log/Log+ContentView.Graph.swift`
- `commit` button `Options` → `Arbor/PullDialogView.swift`
- `commit` menu `Paths:` → `Arbor/PullDialogView.swift`
- `commit` button `Project` → `Arbor/ArborApp.swift`
- `commit` button `Refresh` → `Arbor/FeedbackCenter.swift`
- `commit` button `Revert Selected Changes` → `Arbor/App/ProjectCommands.swift`
- `commit` button `Rollback…` → `Arbor/LogGraphView.swift`
- `commit` textfield `Search` → `Arbor/FileReferenceComparisonView.swift`
- `commit` statictext `Select files to commit and specify commit message` → `Arbor/LogGraphView.swift`
- `commit` button `Shelve Silently` → `Arbor/Panels/Panels+Commit.swift`
- `commit` button `Show Diff` → `Arbor/LogGraphView.swift`
- `commit` button `Terminal` → `Arbor/App/PersistedCommitRecovery.swift`
- `commit` menu `User:` → `Arbor/BitbucketClient.swift`
- `commit` button `View Options` → `Arbor/Panels/Panels+Commit.swift`
- `commit` link `last commit` → `Arbor/ProjectFileTreeView.swift`
- `log` checkbox `Amend` → `Arbor/Settings/DiagnosticsSettingsView.swift`
- `log` menu `Branch:` → `Arbor/PullDialogView.swift`
- `log` button `Cherry-Pick` → `Arbor/LogGraphView.swift`
- `log` button `Collapse All` → `Arbor/Panels/Panels+Core.swift`
- `log` statictext `Commit` → `Arbor/PullDialogView.swift`
- `log` button `Commit` → `Arbor/PullDialogView.swift`
- `log` textview `Commit Message` → `Arbor/LogGraphView.swift`
- `log` button `Commit Message History` → `Arbor/Panels/Panels+Commit.swift`
- `log` button `Commit and Push…` → `Arbor/App/ProjectCommands.swift`
- `log` menu `Date:` → `Arbor/LogGraphView.swift`
- `log` button `Expand All` → `Arbor/LogGraphView.swift`
- `log` button `Git` → `Arbor/AboutView.swift`
- `log` button `Graph Options` → `Arbor/Workspace/Workspace+ContentView.Log.swift`
- `log` button `Open New Git Log Tab` → `Arbor/Log/Log+ContentView.Graph.swift`
- `log` menu `Paths:` → `Arbor/PullDialogView.swift`
- `log` button `Project` → `Arbor/ArborApp.swift`
- `log` button `Refresh` → `Arbor/FeedbackCenter.swift`
- `log` button `Revert Selected Changes` → `Arbor/App/ProjectCommands.swift`
- `log` button `Rollback…` → `Arbor/LogGraphView.swift`
- `log` textfield `Search` → `Arbor/FileReferenceComparisonView.swift`
- `log` statictext `Select files to commit and specify commit message` → `Arbor/LogGraphView.swift`
- `log` button `Shelve Silently` → `Arbor/Panels/Panels+Commit.swift`
- `log` button `Show Commit Options` → `Arbor/Panels/Panels+Commit.swift`
- `log` button `Show Diff` → `Arbor/LogGraphView.swift`
- `log` statictext `Stash` → `Arbor/ResizableWorkspacePanels.swift`
- `log` button `Terminal` → `Arbor/App/PersistedCommitRecovery.swift`
- `log` menu `User:` → `Arbor/BitbucketClient.swift`
- `log` button `View Options` → `Arbor/Panels/Panels+Commit.swift`
- `log` link `last commit` → `Arbor/ProjectFileTreeView.swift`
