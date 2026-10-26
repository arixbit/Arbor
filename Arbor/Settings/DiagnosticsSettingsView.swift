import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers


struct DiagnosticsSettingsView: View {
    @State private var status = ""
    @State private var showReportConfirmation = false
    @State private var showGpgAgentSettings = false
    @State private var updateCheckStatus: String?
    @State private var updateCheckReleaseURL: URL?
    @StateObject private var updateChecker = AppUpdateChecker.shared
    @AppStorage("arbor.git.useCredentialHelper") private var useCredentialHelper = false
    @AppStorage("arbor.git.autoFetch.v1") private var gitAutoFetch = false
    @AppStorage("arbor.git.externalConversion.v1") private var gitExternalConversionEnabled = false
    @AppStorage(GitIncomingCheckStrategy.userDefaultsKey)
    private var incomingCheckStrategyRaw = GitIncomingCheckStrategy.none.rawValue
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @AppStorage(GitInMemoryCommitEditingSettings.key)
    private var inMemoryCommitEditingEnabled = GitInMemoryCommitEditingSettings.defaultValue
    @AppStorage(GitVFSListenerSettings.addActionKey)
    private var gitVFSAddActionRaw = GitVFSListenerAction.ask.rawValue
    @AppStorage(GitVFSListenerSettings.removeActionKey)
    private var gitVFSRemoveActionRaw = GitVFSListenerAction.ask.rawValue
    @AppStorage(GitCloneSettings.recurseSubmodulesKey)
    private var cloneRecursiveSubmodules = GitCloneSettings.defaultRecurseSubmodules
    @AppStorage(GitUpdateInfoAutoOpenSettings.key)
    private var gitUpdateInfoAutoOpen = GitUpdateInfoAutoOpenSettings.defaultValue
    @AppStorage(GitRevisionContentSettings.key)
    private var gitRevisionContentModeRaw = GitRevisionContentSettings.defaultValue
    @AppStorage(GitCommitHooksSettings.key)
    private var gitAlwaysSkipCommitHooks = GitCommitHooksSettings.defaultValue
    @AppStorage(GitBranchNameCleanupSettings.key)
    private var gitBranchCleanupSymbol = GitBranchNameCleanupSettings.defaultValue

    private var incomingCheckStrategy: GitIncomingCheckStrategy {
        resolveGitIncomingCheckStrategy(
            storedRawValue: UserDefaults.standard.object(forKey: GitIncomingCheckStrategy.userDefaultsKey) == nil
                ? nil
                : incomingCheckStrategyRaw,
            legacyAutoFetch: gitAutoFetch
        )
    }

    private var incomingCheckStrategyBinding: Binding<GitIncomingCheckStrategy> {
        Binding(
            get: { incomingCheckStrategy },
            set: { strategy in
                incomingCheckStrategyRaw = strategy.rawValue
                gitAutoFetch = strategy.legacyAutoFetch
            }
        )
    }

    var body: some View {
        Form {
            AppLanguageSettingsSection()
            GitExecutableSettingsSection()
            GitProtectedBranchesSettingsSection()
            GitProtectedBranchSyncSettingsSection()
            GitPushSettingsSection()
            GitLocalChangesSavePolicySettingsSection()
            GitDropCommitSettingsSection()
            GitChangelistSettingsSection()
            GitCherryPickSettingsSection()
            GitMergeSettingsSection()

            Section("Git History Editing") {
                Toggle(
                    "Use in-memory commit editing when possible",
                    isOn: $inMemoryCommitEditingEnabled
                )
                Text("Suitable Log-driven interactive rebase edits use the faster in-memory engine by default. Edits that need a working-directory stop, merge-preserving topology, or the disabled setting use native Git rebase semantics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Commit Signing") {
                Text("Configure the external pinentry used by GPG agent for signed commits. Arbor backs up gpg-agent.conf and reloads the agent after a successful write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Configure GPG Agent…") {
                    showGpgAgentSettings = true
                }
            }

            Section("Git Attributes") {
                Toggle(
                    "Enable Git external conversion and textconv",
                    isOn: $gitExternalConversionEnabled
                )
                Text("When off, Arbor does not run external filters, non-UTF-8 conversion, or textconv from .gitattributes. When on, system Git runs them with a per-conversion timeout. External Diff in the Diff Viewer still requires an explicit action and uses the configured difftool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Historical file content", selection: $gitRevisionContentModeRaw) {
                    ForEach(GitRevisionContentMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode.rawValue)
                    }
                }
                Text("Controls Revision Browser content: raw blobs, checkout filters, or the path's textconv driver. Filters is the IntelliJ-compatible default; external conversion remains an explicit safety setting for other attribute-aware operations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Commit Hooks") {
                Toggle(
                    "Always skip Git commit hooks",
                    isOn: $gitAlwaysSkipCommitHooks
                )
                Text("When enabled, all Arbor commit, amend, and commit-and-push operations pass Git's --no-verify behavior. The per-commit checkbox remains checked and is disabled while this override is active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Branch Names") {
                TextField("Cleanup symbol", text: $gitBranchCleanupSymbol)
                Text("When typing a new branch or Push target, invalid Git ref characters are removed and spaces/control characters are replaced with this symbol. The default is '-'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Clone") {
                Toggle(
                    "Initialize and update submodules recursively",
                    isOn: $cloneRecursiveSubmodules
                )
                Text("New clones use Git's recursive submodule initialization when enabled. This is the same default as IntelliJ's git.clone.recurse.submodules setting and is also available in the Clone dialog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("External Git File Changes") {
                Picker("New untracked files", selection: $gitVFSAddActionRaw) {
                    ForEach(GitVFSListenerAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                Picker("Deleted tracked files", selection: $gitVFSRemoveActionRaw) {
                    ForEach(GitVFSListenerAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                Text("These policies apply when another process creates or deletes files in a Git worktree. Reliable paired renames route both endpoints through the same Add/Remove policy; ambiguous renames remain refresh-only for safety.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Authentication") {
                Toggle("Use Git credential helper", isOn: $useCredentialHelper)
                    .onChange(of: useCredentialHelper) { _, enabled in
                        NotificationCenter.default.post(
                            name: .arborGitCredentialHelperSettingChanged,
                            object: enabled
                        )
                    }
                Text("When disabled, remote operations use Arbor's credential dialog instead of configured Git credential helpers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Git Incoming Changes") {
                Toggle(
                    "Show incoming and outgoing branch information",
                    isOn: $incomingOutgoingInfoEnabled
                )
                Picker("Incoming changes check", selection: incomingCheckStrategyBinding) {
                    ForEach(GitIncomingCheckStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .disabled(!incomingOutgoingInfoEnabled)
                Text("LS_REMOTE checks configured upstreams without changing local refs; Auto-fetch checks every Git root every 20 minutes by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !incomingOutgoingInfoEnabled {
                    Text("The saved incoming-change strategy is retained but inactive until this advanced setting is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Git Update Project") {
                Toggle(
                    "Automatically open the Update Info tab after Update Project",
                    isOn: $gitUpdateInfoAutoOpen
                )
                Text("When enabled, a successful update with received commits opens the dedicated Update Info Log tab. Disable this to keep the current Log tab and use View Commits from the notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Text("Each window focuses on one project; open a new project from the toolbar and choose replace or new window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle(
                    "Automatically Check for Updates",
                    isOn: Binding(
                        get: { AppUpdateChecker.autoCheckEnabled },
                        set: { AppUpdateChecker.setAutoCheckEnabled($0) }
                    )
                )
                Text("Check GitHub Releases online at most once a day; you can also check manually. Only the latest version number is read; no data is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check for Updates Now") {
                        runManualUpdateCheck()
                    }
                    .disabled(updateChecker.isChecking)
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let updateCheckStatus {
                    Text(updateCheckStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let updateCheckReleaseURL {
                    Button("Open Downloads Page") {
                        NSWorkspace.shared.open(updateCheckReleaseURL)
                    }
                }
            }
            Section("Diagnostics") {
                Text("Arbor records operation names, version, repository basename, and error codes only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Export Logs…") { exportLogs() }
                Button("Report a Problem…") { showReportConfirmation = true }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .alert("Open a prefilled GitHub issue?", isPresented: $showReportConfirmation) {
            Button("Open Browser") { openIssueURL() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the version, system version, and a sanitized local log summary will be included.")
        }
        .sheet(isPresented: $showGpgAgentSettings) {
            GpgAgentSettingsView()
        }
    }

    private func runManualUpdateCheck() {
        updateCheckReleaseURL = nil
        updateChecker.checkNow { outcome in
            switch outcome {
            case .updateAvailable(let info, let current):
                updateCheckStatus = "发现新版本 \(info.version)（当前 \(current)）"
                updateCheckReleaseURL = info.releaseURL
            case .upToDate(let current):
                updateCheckStatus = "已是最新版本（\(current)）"
            case .failed(let reason):
                updateCheckStatus = "检查失败：\(reason)"
            case .skipped:
                break
            }
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Arbor-Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsLogger.shared.exportArchive(to: url)
            status = "已导出：\(url.lastPathComponent)"
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }

    private func openIssueURL() {
        var components = URLComponents(string: "https://github.com/arbor/arbor/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Arbor issue"),
            URLQueryItem(
                name: "body",
                value: "Arbor version: \(appVersion)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nDiagnostics: \(DiagnosticsLogger.shared.summary())\n\nReproduction:\n"
            )
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
