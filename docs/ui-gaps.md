# 界面对账得出的缺口清单

由 `scripts/ui-triage.py` 从 `build/parity/*-controls.json` 生成，**不要手改**。
重新生成：`./scripts/ui-parity.sh --reference && python3 scripts/ui-triage.py --write-doc docs/ui-gaps.md`

判定方法：把「参考有、Arbor 缺」的每个名字回查 Arbor 的源码和本地化表。源码里出现过的，说明功能在做、只是叫法或入口位置不同；一次都没出现的才是真缺。

## 疑似真缺

| 界面 | 角色 | 名字 |
| --- | --- | --- |
| commit | button | Enable Git Log Indexing |
| commit | button | Open New Git Log Tab |
| commit | button | Project: visual-fixture, menu |
| commit | button | Rollback… |
| commit | button | Select Opened File in Changes View |
| commit | statictext | Select files to commit and specify commit message |
| commit | button | Update Project... |
| commit | button | main, menu |
| log | button | Enable Git Log Indexing |
| log | button | Open New Git Log Tab |
| log | button | Project: visual-fixture, menu |
| log | button | Rollback… |
| log | button | Select Opened File in Changes View |
| log | statictext | Select files to commit and specify commit message |
| log | button | Update Project... |
| log | button | main, menu |

## 源码里有：叫法或入口位置不同

| 界面 | 名字 | 出现在 |
| --- | --- | --- |
| commit | Branch: | `Arbor/PullDialogView.swift` |
| commit | Cherry-Pick | `Arbor/LogGraphView.swift` |
| commit | Collapse All | `Arbor/Panels/Panels+Core.swift` |
| commit | Commit | `Arbor/PullDialogView.swift` |
| commit | Commit Message | `Arbor/LogGraphView.swift` |
| commit | Date: | `Arbor/LogGraphView.swift` |
| commit | Expand All | `Arbor/LogGraphView.swift` |
| commit | Git | `Arbor/AboutView.swift` |
| commit | Graph Options | `Arbor/Workspace/Workspace+ContentView.Log.swift` |
| commit | Hide | `Arbor/HostingProvider.swift` |
| commit | Options | `Arbor/PullDialogView.swift` |
| commit | Paths: | `Arbor/PullDialogView.swift` |
| commit | Project | `Arbor/ArborApp.swift` |
| commit | Refresh | `Arbor/FeedbackCenter.swift` |
| commit | Revert Selected Changes | `Arbor/App/ProjectCommands.swift` |
| commit | Search | `Arbor/FileReferenceComparisonView.swift` |
| commit | Shelve Silently | `Arbor/Panels/Panels+Commit.swift` |
| commit | Show Diff | `Arbor/LogGraphView.swift` |
| commit | Terminal | `Arbor/App/PersistedCommitRecovery.swift` |
| commit | User: | `Arbor/BitbucketClient.swift` |
| commit | View Options | `Arbor/Panels/Panels+Commit.swift` |
| commit | last commit | `Arbor/ProjectFileTreeView.swift` |
| log | Amend | `Arbor/Settings/DiagnosticsSettingsView.swift` |
| log | Branch: | `Arbor/PullDialogView.swift` |
| log | Cherry-Pick | `Arbor/LogGraphView.swift` |
| log | Collapse All | `Arbor/Panels/Panels+Core.swift` |
| log | Commit | `Arbor/PullDialogView.swift` |
| log | Commit | `Arbor/PullDialogView.swift` |
| log | Commit Message | `Arbor/LogGraphView.swift` |
| log | Commit Message History | `Arbor/Panels/Panels+Commit.swift` |
| log | Commit and Push… | `Arbor/App/ProjectCommands.swift` |
| log | Date: | `Arbor/LogGraphView.swift` |
| log | Expand All | `Arbor/LogGraphView.swift` |
| log | Git | `Arbor/AboutView.swift` |
| log | Graph Options | `Arbor/Workspace/Workspace+ContentView.Log.swift` |
| log | Paths: | `Arbor/PullDialogView.swift` |
| log | Project | `Arbor/ArborApp.swift` |
| log | Refresh | `Arbor/FeedbackCenter.swift` |
| log | Revert Selected Changes | `Arbor/App/ProjectCommands.swift` |
| log | Search | `Arbor/FileReferenceComparisonView.swift` |
| log | Shelve Silently | `Arbor/Panels/Panels+Commit.swift` |
| log | Show Commit Options | `Arbor/Panels/Panels+Commit.swift` |
| log | Show Diff | `Arbor/LogGraphView.swift` |
| log | Stash | `Arbor/ResizableWorkspacePanels.swift` |
| log | Terminal | `Arbor/App/PersistedCommitRecovery.swift` |
| log | User: | `Arbor/BitbucketClient.swift` |
| log | View Options | `Arbor/Panels/Panels+Commit.swift` |
| log | last commit | `Arbor/ProjectFileTreeView.swift` |

## 附：无法通过源码检索判定的条目

名字里带路径、文件名或动态内容，回查没有意义，需要人工看截图。

- `commit` button `Project: visual-fixture, menu`
- `commit` button `Update Project...`
- `commit` button `main, menu`
- `commit` button `Rollback…`
- `commit` button `Select Opened File in Changes View`
- `commit` button `Open New Git Log Tab`
- `commit` button `Enable Git Log Indexing`
- `commit` statictext `Select files to commit and specify commit message`
- `log` button `Project: visual-fixture, menu`
- `log` button `Update Project...`
- `log` button `main, menu`
- `log` button `Rollback…`
- `log` button `Select Opened File in Changes View`
- `log` button `Open New Git Log Tab`
- `log` button `Enable Git Log Indexing`
- `log` statictext `Select files to commit and specify commit message`
