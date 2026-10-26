import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers


struct ProjectGitIncomingChangesSettingsView: View {
    let projectPath: String
    let rootPaths: [String]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: GitIncomingProjectSettingChoice
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @State private var rootSyncChoice: GitRootSyncChoice
    @State private var useProjectProtectedBranchSettings: Bool
    @State private var protectedBranchPatterns: String
    @State private var synchronizeProtectedBranches: Bool
    @State private var useProjectGitExecutable: Bool
    @State private var projectGitExecutablePath: String
    @State private var projectGitExecutableStatus = ""
    @State private var projectGitExecutableSaveError: String?
    @State private var fetchTagsMode: GitFetchTagsModeChoice
    @State private var updateMethod: GitUpdateMethodChoice
    @State private var updateInfoPathFilterText: String
    @State private var useProjectLocalChangesSavePolicy: Bool
    @State private var localChangesSavePolicy: GitLocalChangesSavePolicyChoice
    @State private var useProjectPushAfterCommitPreview: Bool
    @State private var pushAfterCommitPreview: GitPushAfterCommitPreviewChoice
    @State private var useProjectCherryPickSettings: Bool
    @State private var projectCherryPickAppendPublishedSuffix: Bool
    @State private var useProjectPushTagSettings: Bool
    @State private var projectPushTagMode: PushDialogTagMode
    @State private var autoUpdateIfPushRejected: Bool
    @State private var signOffCommit: Bool
    @State private var swapSidesInCompareBranches: Bool
    @State private var resetMode: GitResetModeChoice
    @State private var warnAboutCrlf: Bool
    @State private var warnAboutDetachedHead: Bool
    @State private var warnAboutLargeFiles: Bool
    @State private var warnAboutBadFileNames: Bool
    @State private var largeFileLimitMBText: String

    init(
        projectPath: String,
        rootPaths: [String] = [],
        onSaved: @escaping () -> Void
    ) {
        self.projectPath = projectPath
        self.rootPaths = rootPaths
        self.onSaved = onSaved
        _choice = State(
            initialValue: GitIncomingCheckStrategySettings.projectChoice(for: projectPath)
        )
        _rootSyncChoice = State(
            initialValue: GitRootSyncSettings.choice(for: projectPath)
        )
        let projectPatterns = GitProtectedBranchRules.projectRawValue(for: projectPath)
        let projectSynchronize = GitProtectedBranchRules.projectSynchronizeValue(for: projectPath)
        _useProjectProtectedBranchSettings = State(
            initialValue: projectPatterns != nil || projectSynchronize != nil
        )
        _protectedBranchPatterns = State(
            initialValue: projectPatterns ?? GitProtectedBranchRules.globalRawValue()
        )
        _synchronizeProtectedBranches = State(
            initialValue: projectSynchronize
                ?? GitProtectedBranchRules.synchronizeRemotePatterns()
        )
        let projectGitExecutable = GitExecutableSettings.projectOverride(for: projectPath)
        _useProjectGitExecutable = State(initialValue: projectGitExecutable != nil)
        _projectGitExecutablePath = State(initialValue: projectGitExecutable ?? gitExecutable())
        _fetchTagsMode = State(initialValue: GitFetchTagsSettings.mode(for: projectPath))
        _updateMethod = State(initialValue: GitUpdateMethodSettings.method(for: projectPath))
        _updateInfoPathFilterText = State(
            initialValue: GitUpdateInfoPathFilterSettings.text(for: projectPath)
        )
        let projectSavePolicy = GitProjectLocalChangesSavePolicySettings.choice(for: projectPath)
        _useProjectLocalChangesSavePolicy = State(initialValue: projectSavePolicy != nil)
        _localChangesSavePolicy = State(
            initialValue: projectSavePolicy ?? GitLocalChangesSavePolicySettings.choice()
        )
        let projectPushPreview = GitPushAfterCommitSettings.projectChoice(for: projectPath)
        _useProjectPushAfterCommitPreview = State(initialValue: projectPushPreview != nil)
        _pushAfterCommitPreview = State(
            initialValue: projectPushPreview
                ?? GitPushAfterCommitSettings.choice(from: UserDefaults.standard)
        )
        let projectCherryPickSuffix = GitCherryPickSettings.projectAppendPublishedSuffix(
            for: projectPath
        )
        _useProjectCherryPickSettings = State(initialValue: projectCherryPickSuffix != nil)
        _projectCherryPickAppendPublishedSuffix = State(
            initialValue: projectCherryPickSuffix
                ?? GitCherryPickSettings.appendPublishedSuffix()
        )
        let projectPushTagMode = GitPushTagSettings.projectTagMode(for: projectPath)
        _useProjectPushTagSettings = State(
            initialValue: GitPushTagSettings.hasProjectOverride(for: projectPath)
        )
        _projectPushTagMode = State(initialValue: projectPushTagMode ?? .all)
        _autoUpdateIfPushRejected = State(
            initialValue: GitPushAutoUpdateSettings.value(for: projectPath)
        )
        _signOffCommit = State(
            initialValue: GitSignOffCommitSettings.value(for: projectPath)
        )
        _swapSidesInCompareBranches = State(
            initialValue: GitCompareBranchesSettings.swapSides(for: projectPath)
        )
        _resetMode = State(
            initialValue: GitResetModeSettings.mode(for: projectPath)
        )
        _warnAboutCrlf = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.crlf, for: projectPath)
        )
        _warnAboutDetachedHead = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.detachedHead, for: projectPath)
        )
        _warnAboutLargeFiles = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.largeFile, for: projectPath)
        )
        _warnAboutBadFileNames = State(
            initialValue: GitCommitWarningSettings.warningEnabled(.badFileName, for: projectPath)
        )
        _largeFileLimitMBText = State(
            initialValue: String(GitCommitWarningSettings.largeFileLimitMB(for: projectPath))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Git Settings")
                .font(.title2.weight(.semibold))
            Text(projectPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Form {
                Picker("Incoming changes check", selection: $choice) {
                    ForEach(GitIncomingProjectSettingChoice.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .disabled(!incomingOutgoingInfoEnabled)
                Text("This setting applies only to this project. Use the global setting to inherit the app-wide Git preference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !incomingOutgoingInfoEnabled {
                    Text("Incoming and outgoing branch information is disabled by the global Git advanced setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("LS_REMOTE checks configured upstreams without changing local refs; Auto-fetch checks every Git root every 20 minutes by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Section("Update Project") {
                    Picker("Update method", selection: $updateMethod) {
                        ForEach(GitUpdateMethodChoice.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(updateMethod.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This setting applies to Update Project (⌘T), including every discovered Git root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Update Info path filter")
                        TextEditor(text: $updateInfoPathFilterText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 64, maxHeight: 120)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            }
                        Text("One path per line; use an absolute path to target one Git root. Leave empty to show all updated paths.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Use project-specific local changes policy",
                        isOn: $useProjectLocalChangesSavePolicy
                    )
                    Picker("Save local changes as", selection: $localChangesSavePolicy) {
                        ForEach(GitLocalChangesSavePolicyChoice.allCases) { policy in
                            Text(LocalizedStringKey(policy.title)).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!useProjectLocalChangesSavePolicy)
                    Text(LocalizedStringKey(localChangesSavePolicy.detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        useProjectLocalChangesSavePolicy
                            ? "This project policy is used by Pull, Update Project, Rebase, Merge, Reset, and smart checkout operations."
                            : "This project inherits the application Local Changes Preservation setting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Branch operations") {
                    Picker("Cross-root action scope", selection: $rootSyncChoice) {
                        ForEach(GitRootSyncChoice.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(rootSyncChoice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This project setting controls whether same-name Branch Popup actions can target multiple Git roots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fetch tags") {
                    Picker("Tag handling", selection: $fetchTagsMode) {
                        ForEach(GitFetchTagsModeChoice.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(fetchTagsMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This project setting applies to Fetch, Fetch All, Pull, Checkout and Update, remote-branch Fetch, incoming-change checks, and Push recovery updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Commit and Push") {
                    Toggle(
                        "Use project-specific Push-after-commit behavior",
                        isOn: $useProjectPushAfterCommitPreview
                    )
                    Picker("After Commit and Push", selection: $pushAfterCommitPreview) {
                        ForEach(GitPushAfterCommitPreviewChoice.allCases) { choice in
                            Text(LocalizedStringKey(choice.title)).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!useProjectPushAfterCommitPreview)
                    Text(LocalizedStringKey(pushAfterCommitPreview.detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        useProjectPushAfterCommitPreview
                            ? "This project overrides the application Push-after-commit behavior."
                            : "This project inherits the application Push-after-commit behavior."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Commit defaults") {
                    Toggle(
                        "Add Signed-off-by by default",
                        isOn: $signOffCommit
                    )
                    Text("This project setting is the default for single-root and multi-root Commit dialogs. The existing identity sheet can still change the current session's one-shot commit options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Compare branches") {
                    Toggle(
                        "Swap sides in branch diff",
                        isOn: $swapSidesInCompareBranches
                    )
                    Text(
                        swapSidesInCompareBranches
                            ? "Show the selected branch on the left and the current working tree on the right."
                            : "Show the current working tree on the left and the selected branch on the right."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Reset") {
                    Picker("Default reset mode", selection: $resetMode) {
                        ForEach(GitResetModeChoice.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(LocalizedStringKey(resetMode.detail))
                        .font(.caption)
                        .foregroundStyle(resetMode == .hard ? .red : .secondary)
                    Text("Reset dialogs remember the last mode selected in this project. Hard reset remains explicitly destructive and requires confirmation in the dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Commit warnings") {
                    Toggle("Warn about mixed CRLF/LF line endings", isOn: $warnAboutCrlf)
                    Toggle("Warn when committing with detached HEAD", isOn: $warnAboutDetachedHead)
                    Toggle("Warn about large staged files", isOn: $warnAboutLargeFiles)
                    HStack {
                        Text("Large-file threshold (MB)")
                        Spacer()
                        TextField("50", text: $largeFileLimitMBText)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    .disabled(!warnAboutLargeFiles)
                    Toggle("Warn about Windows-incompatible file names", isOn: $warnAboutBadFileNames)
                    Text("These checks run before single-root and multi-root Commit. Continue or cancel is offered for each warning group; choosing not to warn again disables that warning for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Cherry-pick") {
                    Toggle(
                        "Use project-specific Cherry-pick behavior",
                        isOn: $useProjectCherryPickSettings
                    )
                    Toggle(
                        "Add published-commit suffix",
                        isOn: $projectCherryPickAppendPublishedSuffix
                    )
                    .disabled(!useProjectCherryPickSettings)
                    Text(
                        useProjectCherryPickSettings
                            ? "This project overrides whether Cherry-pick adds the suffix for commits already reachable from a protected remote branch."
                            : "This project inherits the application Cherry-pick suffix setting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Push tags") {
                    Toggle(
                        "Use project-specific Push tag mode",
                        isOn: $useProjectPushTagSettings
                    )
                    Picker("Default tag mode", selection: $projectPushTagMode) {
                        ForEach(PushDialogTagMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!useProjectPushTagSettings)
                    Text(
                        useProjectPushTagSettings
                            ? "Push dialogs default to this tag mode for this project; the user can still disable Push tags per operation."
                            : "Push dialogs default to Push tags off for this project."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Push recovery") {
                    Toggle(
                        "Auto-update if current-branch Push is rejected",
                        isOn: $autoUpdateIfPushRejected
                    )
                    Text("When a Push of the checked-out branch is rejected because the remote is ahead, Arbor updates the project roots with the selected Update method and retries. Force pushes, custom refspecs, non-current branches, and branches without an upstream remain manual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Git Executable") {
                    Toggle(
                        "Use project-specific Git executable",
                        isOn: $useProjectGitExecutable
                    )
                    HStack(spacing: 8) {
                        TextField("Path to Git executable", text: $projectGitExecutablePath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!useProjectGitExecutable)
                        Button("Browse…", action: chooseProjectGitExecutable)
                            .disabled(!useProjectGitExecutable)
                    }
                    HStack(spacing: 8) {
                        Button("Test Git executable", action: testProjectGitExecutable)
                            .disabled(!useProjectGitExecutable || projectGitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !projectGitExecutableStatus.isEmpty {
                            Text(projectGitExecutableStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let projectGitExecutableSaveError {
                        Label(projectGitExecutableSaveError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    Text(
                        useProjectGitExecutable
                            ? "This executable is used by this project’s registered Git roots and overrides the application default."
                            : "This project inherits the application Git executable."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle(
                    "Use project-specific protected branch rules",
                    isOn: $useProjectProtectedBranchSettings
                )
                .help("When disabled, this project inherits the global protected branch settings.")
                ProjectGitProtectedBranchesSettingsSection(
                    patterns: $protectedBranchPatterns,
                    synchronize: $synchronizeProtectedBranches
                )
                .disabled(!useProjectProtectedBranchSettings)
                if !useProjectProtectedBranchSettings {
                    Text("This project inherits the global protected branch patterns and synchronization setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    guard saveProjectGitExecutable() else { return }
                    GitIncomingCheckStrategySettings.saveProjectStrategy(
                        choice.strategy,
                        for: projectPath
                    )
                    GitRootSyncSettings.save(rootSyncChoice, for: projectPath)
                    GitFetchTagsSettings.save(fetchTagsMode, for: projectPath)
                    GitUpdateMethodSettings.save(updateMethod, for: projectPath)
                    GitUpdateInfoPathFilterSettings.save(
                        updateInfoPathFilterText,
                        roots: rootPaths,
                        for: projectPath
                    )
                    GitProjectLocalChangesSavePolicySettings.save(
                        useProjectLocalChangesSavePolicy ? localChangesSavePolicy : nil,
                        for: projectPath
                    )
                    GitPushAfterCommitSettings.saveProjectChoice(
                        useProjectPushAfterCommitPreview ? pushAfterCommitPreview : nil,
                        for: projectPath
                    )
                    GitCherryPickSettings.saveProjectAppendPublishedSuffix(
                        useProjectCherryPickSettings
                            ? projectCherryPickAppendPublishedSuffix
                            : nil,
                        for: projectPath
                    )
                    GitPushTagSettings.saveProjectTagMode(
                        useProjectPushTagSettings ? projectPushTagMode : nil,
                        for: projectPath
                    )
                    GitPushAutoUpdateSettings.save(
                        autoUpdateIfPushRejected,
                        for: projectPath
                    )
                    GitSignOffCommitSettings.saveProjectValue(
                        signOffCommit,
                        for: projectPath
                    )
                    GitCompareBranchesSettings.saveSwapSides(
                        swapSidesInCompareBranches,
                        for: projectPath
                    )
                    GitResetModeSettings.save(
                        resetMode,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutCrlf,
                        .crlf,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutDetachedHead,
                        .detachedHead,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutLargeFiles,
                        .largeFile,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveLargeFileLimitMB(
                        Int(largeFileLimitMBText.trimmingCharacters(in: .whitespacesAndNewlines))
                            ?? GitCommitWarningSettings.defaultLargeFileLimitMB,
                        for: projectPath
                    )
                    GitCommitWarningSettings.saveWarning(
                        warnAboutBadFileNames,
                        .badFileName,
                        for: projectPath
                    )
                    if useProjectProtectedBranchSettings {
                        GitProtectedBranchRules.saveProjectPatterns(
                            protectedBranchPatterns,
                            for: projectPath
                        )
                        GitProtectedBranchRules.saveProjectSynchronize(
                            synchronizeProtectedBranches,
                            for: projectPath
                        )
                    } else {
                        GitProtectedBranchRules.saveProjectPatterns(nil, for: projectPath)
                        GitProtectedBranchRules.saveProjectSynchronize(nil, for: projectPath)
                    }
                    onSaved()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseProjectGitExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            projectGitExecutablePath = url.path
            projectGitExecutableStatus = ""
            projectGitExecutableSaveError = nil
        }
    }

    private func testProjectGitExecutable() {
        let candidate = projectGitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        projectGitExecutableStatus = "Testing…"
        projectGitExecutableSaveError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let version = try testGitExecutable(path: candidate)
                await MainActor.run {
                    projectGitExecutableStatus = version
                }
            } catch {
                await MainActor.run {
                    projectGitExecutableStatus = "Test failed: \(error)"
                }
            }
        }
    }

    private func saveProjectGitExecutable() -> Bool {
        projectGitExecutableSaveError = nil
        if !useProjectGitExecutable {
            GitExecutableSettings.saveProjectOverride(nil, for: projectPath)
            clearProjectGitExecutable(projectPath: projectPath)
            return true
        }

        let candidate = projectGitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            projectGitExecutableSaveError = "Project Git executable path must not be empty."
            return false
        }
        do {
            let roots = GitExecutableSettings.registeredRoots(
                projectPath: projectPath,
                repositoryRoot: nil,
                discoveredRoots: rootPaths
            )
            let selected = try setProjectGitExecutable(
                projectPath: projectPath,
                rootPaths: roots,
                path: candidate
            )
            GitExecutableSettings.saveProjectOverride(selected, for: projectPath)
            projectGitExecutablePath = selected
            projectGitExecutableStatus = "Saved: \(selected)"
            return true
        } catch {
            projectGitExecutableSaveError = "Save failed: \(error)"
            return false
        }
    }
}
