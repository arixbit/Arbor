import SwiftUI

/// LFS 工作页：把 `git-lfs` 的能力、跟踪规则、文件列表和传输动作收敛到
/// 一个可操作的面板。视图本身不持有仓库句柄，所有动作通过闭包回到
/// `ContentView`，这样 LFS 操作和其它 Git 操作复用同一套刷新/反馈链路。
struct LfsPanelView: View {
    let capability: LfsCapability?
    let patterns: [LfsTrackedPattern]
    let files: [LfsFileEntry]
    let hooks: LfsHookState?
    let busy: Bool
    let feedback: String?
    @Binding var selectedPaths: Set<String>

    @Binding var trackInput: String
    @Binding var showAllRevisions: Bool
    @Binding var remoteName: String

    let onRefresh: () -> Void
    let onTrack: () -> Void
    let onUntrack: (String) -> Void
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onFetch: () -> Void
    let onPull: () -> Void
    let onPush: () -> Void
    let onPrune: () -> Void
    let onCheckout: () -> Void
    let onDismiss: () -> Void

    @State private var patternToRemove: String?

    private var installed: Bool { capability?.installed == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !installed {
                missingLfsView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hooksSection
                        patternsSection
                        filesSection
                    }
                    .padding(18)
                }
                Divider()
                transportBar
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Git LFS").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Refresh", action: onRefresh)
                .disabled(busy)
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var subtitle: String {
        guard let capability else { return "Git LFS 状态读取中…" }
        if capability.installed {
            return "git-lfs \(capability.version ?? "unknown") · \(files.count) 个 LFS 文件 · \(patterns.count) 条跟踪规则"
        }
        return "未检测到 git-lfs"
    }

    private var missingLfsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Git LFS is not available", systemImage: "exclamationmark.triangle")
                .font(.headline)
            if let detail = capability?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Text("After installing, reopen this panel: run `brew install git-lfs`, then `git lfs install` in a terminal.")
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var hooksSection: some View {
        GroupBox("Repository hooks") {
            HStack(spacing: 14) {
                hookBadge("post-checkout", hooks?.postCheckout == true)
                hookBadge("post-commit", hooks?.postCommit == true)
                hookBadge("post-merge", hooks?.postMerge == true)
                hookBadge("pre-push", hooks?.prePush == true)
                Spacer()
                if hooks?.postCheckout == true, hooks?.prePush == true {
                    Button("Uninstall", action: onUninstall).disabled(busy)
                } else {
                    Button("Install", action: onInstall).disabled(busy)
                }
            }
            .padding(6)
        }
    }

    private func hookBadge(_ name: String, _ installed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? Color.green : Color.secondary)
            Text(name).font(.callout.monospaced())
        }
    }

    private var patternsSection: some View {
        GroupBox("Tracked patterns") {
            VStack(alignment: .leading, spacing: 10) {
                if patterns.isEmpty {
                    Text("No tracking rules yet. Enter a pattern (for example `*.psd`) and click Track; git-lfs writes .gitattributes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(patterns, id: \.pattern) { pattern in
                        HStack {
                            Text(pattern.pattern).font(.callout.monospaced())
                            Spacer()
                            Text(pattern.source)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                patternToRemove = pattern.pattern
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy)
                        }
                    }
                }
                HStack {
                    TextField("*.bin", text: $trackInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onTrack)
                    Button("Track", action: onTrack)
                        .disabled(busy || trackInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(6)
        }
        .alert("Stop tracking pattern?", isPresented: Binding(
            get: { patternToRemove != nil },
            set: { if !$0 { patternToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { patternToRemove = nil }
            Button("Untrack", role: .destructive) {
                if let pattern = patternToRemove { onUntrack(pattern) }
                patternToRemove = nil
            }
        } message: {
            Text("从 .gitattributes 里移除 \(patternToRemove ?? "")。已提交的对象不会删除。")
        }
    }

    private var filesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("All revisions", isOn: $showAllRevisions)
                        .toggleStyle(.checkbox)
                        .onChange(of: showAllRevisions) { _, _ in onRefresh() }
                    Spacer()
                    Text("\(files.filter { !$0.contentPresent }.count) 个未下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if files.isEmpty {
                    Text("No LFS files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(files, id: \.path) { file in
                                fileRow(file)
                            }
                        }
                    }
                    .frame(minHeight: 180)
                }
            }
            .padding(6)
        } label: {
            Text("LFS files")
        }
    }

    private func fileRow(_ file: LfsFileEntry) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selectedPaths.contains(file.path) },
                set: { selected in
                    if selected { selectedPaths.insert(file.path) } else { selectedPaths.remove(file.path) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Image(systemName: file.contentPresent ? "internaldrive.fill" : "icloud.and.arrow.down")
                .foregroundStyle(file.contentPresent ? Color.secondary : Color.orange)
            Text(file.path).font(.callout.monospaced())
            Spacer()
            Text(String(file.oid.prefix(12)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(file.contentPresent ? "downloaded" : "pointer")
                .font(.caption)
                .foregroundStyle(file.contentPresent ? Color.secondary : Color.orange)
                .frame(width: 78, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            if let feedback, !feedback.isEmpty {
                Text(feedback)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("remote", text: $remoteName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Button("Fetch", action: onFetch).disabled(busy)
            Button("Pull", action: onPull).disabled(busy)
            Button("Checkout", action: onCheckout).disabled(busy || selectedPaths.isEmpty)
            Button("Push", action: onPush).disabled(busy)
            Button("Prune", action: onPrune).disabled(busy)
        }
        .padding(14)
    }
}
