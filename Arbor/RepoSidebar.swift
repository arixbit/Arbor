import SwiftUI
import AppKit

extension ContentView {
// MARK: 分支侧栏（merge + 分支 + stash）

var repoSidebar: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("合并").font(.headline)
                HStack(spacing: 6) {
                    TextField("分支名", text: $mergeWorkspace.branch)
                        .textFieldStyle(.roundedBorder)
                    Button("合并") { doMerge() }
                }
                if let mergeFeedback = mergeWorkspace.feedback {
                    Text(mergeFeedback).font(.caption)
                        .foregroundStyle(mergeFeedback.hasPrefix("冲突") ? .red : .green)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("分支").font(.headline)
                HStack(spacing: 6) {
                    TextField("新分支名", text: $branchWorkspace.newName).textFieldStyle(.roundedBorder)
                    Button("创建") { branchCreate() }
                }
                HStack(spacing: 6) {
                    TextField("旧名", text: $branchWorkspace.renameOld).textFieldStyle(.roundedBorder)
                    TextField("新名", text: $branchWorkspace.renameNew).textFieldStyle(.roundedBorder)
                    Button("重命名") { branchRename() }
                }
                Button("删除已合并分支") { deleteMergedBranches() }
                    .help("删除已合并入 HEAD 的本地分支")
                    .disabled(branchWorkspace.branches.isEmpty)
                ForEach(branchWorkspace.branches, id: \.name) { b in
                    HStack(spacing: 6) {
                        Text(b.name).font(.system(.body, design: .monospaced)).bold(b.isCurrent)
                        Text(b.shortId).font(.caption).foregroundStyle(.secondary)
                        if let compare = branchWorkspace.comparisons[b.name], compare.ahead > 0 || compare.behind > 0 {
                            Text("↑\(compare.ahead) ↓\(compare.behind)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if b.isCurrent {
                            Text("当前").font(.caption2).foregroundStyle(.blue)
                        } else {
                            Button("切换") { switchBranch(b.name) }
                            Button("删除") { branchDelete(b.name) }
                            pullRequestAction(for: b.name)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Stash").font(.headline)
                HStack(spacing: 6) {
                    TextField("说明（可选）", text: $stashUI.message).textFieldStyle(.roundedBorder)
                    Button("保存") { stashSave() }
                }
                ForEach(stashUI.stashes, id: \.id) { s in
                    HStack(spacing: 6) {
                        Text(s.message).font(.caption).lineLimit(1)
                        Text(s.shortId).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("弹出") { stashPop(stashID: s.id) }
                        Button("丢弃") { stashDrop(stashID: s.id) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Shelve").font(.headline)
                HStack(spacing: 6) {
                    TextField("补丁名", text: $shelfWorkspace.name).textFieldStyle(.roundedBorder)
                    Button("保存全部变更") { doShelve() }
                        .disabled(repositoryStatus.entries.isEmpty || shelfWorkspace.name.isEmpty)
                }
                ForEach(shelfWorkspace.shelves, id: \.name) { s in
                    HStack(spacing: 6) {
                        Text(s.name).font(.caption).lineLimit(1)
                        Text(s.shortId).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("弹出") { doShelvePop(s.name) }
                        Button("丢弃") { doShelveDrop(s.name) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("远程").font(.headline)
                HStack(spacing: 6) {
                    TextField("远程名", text: $remoteWorkspace.name).textFieldStyle(.roundedBorder).frame(width: 80)
                    TextField("URL", text: $remoteWorkspace.url).textFieldStyle(.roundedBorder)
                    Button("添加") { remoteAdd() }
                }
                ForEach(remoteWorkspace.remotes, id: \.name) { r in
                    HStack(spacing: 6) {
                        Text(r.name).font(.system(.body, design: .monospaced))
                        Text(r.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Toggle("force", isOn: $pushWorkspace.force).toggleStyle(.checkbox).font(.caption)
                        Button("fetch") { doFetch(r.name) }
                        Menu("pull") {
                            Button("merge") { doPull(r.name, rebase: false) }
                            Button("--rebase") { doPull(r.name, rebase: true) }
                        }
                        Button("push") { doPush(r.name) }
                        Button("移除") { remoteRemove(r.name) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("变基").font(.headline)
                HStack(spacing: 10) {
                    Toggle("保留 merge", isOn: $rebaseWorkspace.preserveMerges)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("autosquash", isOn: $rebaseWorkspace.autoSquash)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                HStack(spacing: 10) {
                    Toggle("保留空提交", isOn: $rebaseWorkspace.keepEmpty)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("更新 refs", isOn: $rebaseWorkspace.updateRefs)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("从 root", isOn: $rebaseWorkspace.root)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    TextField("onto（提交 id）", text: $rebaseWorkspace.onto).textFieldStyle(.roundedBorder)
                    Button("加载范围") { loadRebaseRange() }
                    Button("开始变基") { doRebase() }
                        .disabled(rebaseWorkspace.range.isEmpty)
                }
                if rebaseWorkspace.paused {
                    HStack(spacing: 6) {
                        if rebaseWorkspace.pauseReason == .conflict {
                            Text("已暂停在冲突（\(rebaseWorkspace.conflicts.count) 个文件）")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("已暂停在 edit 提交（可改文件）")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("继续") { doRebaseContinue() }
                        Button("中止") { doRebaseAbort() }
                    }
                    if rebaseWorkspace.pauseReason == .conflict, !rebaseWorkspace.conflicts.isEmpty {
                        Text(rebaseWorkspace.conflicts.prefix(5).joined(separator: "、"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let rebaseFeedback = rebaseWorkspace.feedback {
                    Text(rebaseFeedback).font(.caption)
                        .foregroundStyle(rebaseFeedback.hasPrefix("冲突") ? .red : .green)
                }
                ForEach(Array(rebaseWorkspace.range.enumerated()), id: \.offset) { i, c in
                    HStack {
                        Text(c.shortId).font(.caption2).foregroundStyle(.secondary)
                        Text(c.summary).font(.caption).lineLimit(1)
                        Spacer()
                        Picker("", selection: rebaseActionBinding(i)) {
                            Text("pick").tag(RebaseAction.pick)
                            Text("drop").tag(RebaseAction.drop)
                            Text("squash").tag(RebaseAction.squash)
                            Text("edit").tag(RebaseAction.edit)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 96)
                        Button("reword") { promptReword(index: i, defaultMessage: c.summary) }
                            .font(.caption)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("子模块").font(.headline)
                HStack(spacing: 6) {
                    TextField("URL", text: $submoduleWorkspace.url).textFieldStyle(.roundedBorder)
                    TextField("路径", text: $submoduleWorkspace.path).textFieldStyle(.roundedBorder)
                    Button("添加") { submoduleAdd() }
                }
                Button("更新所有子模块") { submoduleUpdate() }
                HStack(spacing: 6) {
                    Button("同步配置") { submoduleSync() }
                    Button("刷新") { loadSubmodules() }
                }
                ForEach(submoduleWorkspace.submodules, id: \.path) { module in
                    HStack(spacing: 6) {
                        Text(module.path).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(module.headId.prefix(7))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(submoduleStateName(module.state))
                            .font(.caption2)
                            .foregroundStyle(module.state == .clean ? .green : .orange)
                        Button("移除") { submoduleRemove(module.path) }
                            .buttonStyle(.borderless)
                    }
                }
                if let submoduleFeedback = submoduleWorkspace.feedback {
                    Text(submoduleFeedback).font(.caption)
                        .foregroundStyle(submoduleFeedback.hasPrefix("已") ? .green : .red)
                }
            }
        }
        .padding(10)
        .onChange(of: rebaseWorkspace.preserveMerges) { _, _ in
            invalidateLoadedRebaseRange()
        }
        .onChange(of: rebaseWorkspace.root) { _, _ in
            invalidateLoadedRebaseRange()
        }
    }
}

@ViewBuilder
private func pullRequestAction(for branch: String) -> some View {
    let candidates = pullRequestRemotes(for: branch)
    switch hostedRemoteActionPresentation(for: candidates.count) {
    case .direct where candidates.count == 1:
        Button("PR") { openPR(branch, remote: candidates[0]) }
    case .submenu:
        Menu("PR") {
            ForEach(candidates, id: \.name) { remote in
                Button(remote.name) {
                    openPR(branch, remote: remote)
                }
            }
        }
    case .direct, .hidden:
        EmptyView()
    }
}

private func pullRequestRemotes(for branch: String) -> [RemoteInfo] {
    guard let repo else { return [] }
    return remoteWorkspace.remotes.filter { remote in
        repo.prUrl(remoteUrl: remote.url, branch: branch) != nil
    }
}

private func submoduleStateName(_ state: SubmoduleState) -> String {
    switch state {
    case .clean: return "clean"
    case .modified: return "modified"
    case .uninitialized: return "uninitialized"
    case .conflict: return "conflict"
    case .missing: return "missing"
    case .unknown: return "unknown"
    }
}


}
