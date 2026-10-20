import SwiftUI
import AppKit
import UniformTypeIdentifiers


enum GitExecutableSettings {
    static let applicationKey = "arbor.git.executable"
    private static let projectKeyPrefix = "arbor.git.executable.project.v1:"

    private static func projectKey(for projectPath: String) -> String {
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(projectKeyPrefix)\(data.base64EncodedString())"
    }

    static func projectOverride(
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let value = defaults.string(forKey: projectKey(for: projectPath))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func saveProjectOverride(
        _ path: String?,
        for projectPath: String,
        defaults: UserDefaults = .standard
    ) {
        let key = projectKey(for: projectPath)
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(path, forKey: key)
    }

    static func registeredRoots(
        projectPath: String,
        repositoryRoot: String?,
        discoveredRoots: [String]
    ) -> [String] {
        var paths = [projectPath]
        if let repositoryRoot, !repositoryRoot.isEmpty {
            paths.append(repositoryRoot)
        }
        paths.append(contentsOf: discoveredRoots)
        return Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
    }
}

/// Application-level Git executable selection, matching IntelliJ's
/// GitExecutableManager boundary. The selected path is validated before it is
/// persisted and is used by every system-Git command in the Rust engine.
struct GitExecutableSettingsSection: View {
    @AppStorage(GitExecutableSettings.applicationKey) private var savedPath = ""
    @State private var path = ""
    @State private var version = ""
    @State private var message = ""
    @State private var isBusy = false

    var body: some View {
        Section("Git Executable") {
            Text("Select the Git executable used by Arbor's system Git operations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Path to Git executable", text: $path)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…", action: chooseExecutable)
            }
            HStack(spacing: 8) {
                Button("Test Git executable", action: testExecutable)
                    .disabled(isBusy)
                Button("Save Git executable", action: saveExecutable)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                Button("Reset to PATH default", action: resetExecutable)
                    .disabled(isBusy)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !version.isEmpty {
                Text("Current version: \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !message.isEmpty {
                Label(message, systemImage: version.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(version.isEmpty ? .orange : .green)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            path = gitExecutable()
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            message = ""
            version = ""
        }
    }

    private func testExecutable() {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        message = ""
        version = ""
        Task.detached(priority: .userInitiated) {
            do {
                let result = try testGitExecutable(path: candidate)
                await MainActor.run {
                    self.version = result
                    self.message = "Git executable is valid"
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.message = "Git executable test failed: \(error)"
                    self.isBusy = false
                }
            }
        }
    }

    private func saveExecutable() {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        message = ""
        version = ""
        Task.detached(priority: .userInitiated) {
            do {
                let selected = try setGitExecutable(path: candidate)
                let result = try gitExecutableVersion()
                await MainActor.run {
                    self.path = selected
                    self.savedPath = selected == "git" ? "" : selected
                    self.version = result
                    self.message = "Git executable saved"
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.message = "Git executable save failed: \(error)"
                    self.isBusy = false
                }
            }
        }
    }

    private func resetExecutable() {
        path = ""
        saveExecutable()
    }
}
