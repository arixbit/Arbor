import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Git reports several different pinentry/GPG failures for the same user
/// action. Keep the classifier narrow enough that an SSH signing failure does
/// not incorrectly send the user to GPG settings.
func gitCommitSigningFailureNeedsGPGConfiguration(_ message: String) -> Bool {
    let normalized = message.lowercased()
    if normalized.contains("ssh-keygen")
        || normalized.contains("ssh signing")
        || normalized.contains("signing format: ssh") {
        return false
    }
    return normalized.contains("gpg failed to sign")
        || normalized.contains("gpg: signing failed")
        || normalized.contains("gpg: no secret key")
        || normalized.contains("secret key not available")
        || normalized.contains("pinentry")
}

func gnuPGAvailabilityFailure(_ message: String) -> Bool {
    let normalized = message.lowercased()
    if normalized.contains("cannot resolve gnupg home directory") {
        return true
    }
    return normalized.contains("gpgconf")
        && (normalized.contains("cannot start")
            || normalized.contains("not found")
            || normalized.contains("no such file"))
}

enum GnuPGInstallationGuide {
    static let downloadURL = URL(string: "https://gnupg.org/download/")!
}

/// The embedded helper is a small launcher plus the Arbor executable's
/// `--arbor-pinentry` mode. The launcher selects the helper for an Arbor
/// pinentry session and forwards remote-development entrypoints; all other
/// GPG callers use the detected system pinentry.
enum ArborEmbeddedPinentry {
    static let remoteEntrypointPrefix = "IJ_PINENTRY_ENTRYPOINT="

    static var launcherURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupport
            .appendingPathComponent("Arbor", isDirectory: true)
            .appendingPathComponent("gpg-pinentry-launcher")
    }

    static func isConfigured(_ path: String?) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == launcherURL.standardizedFileURL.path
    }

    static func configure() throws -> GpgAgentStatus {
        let current = try gpgAgentStatus()
        let launcherPath = launcherURL.standardizedFileURL.path
        let launcher = try installLauncher(
            fallbackPath: [current.pinentryProgram, current.defaultPinentryProgram]
                .compactMap { $0 }
                .first { path in
                    URL(fileURLWithPath: path).standardizedFileURL.path
                        != launcherPath
                }
        )
        return try configureGpgAgent(pinentryProgram: launcher.path)
    }

    private static func installLauncher(fallbackPath: String?) throws -> URL {
        guard let executable = Bundle.main.executablePath, !executable.isEmpty else {
            throw NSError(
                domain: "Arbor.GPGPinentry",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Arbor executable path is unavailable."]
            )
        }

        let launcher = launcherURL
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = launcherScript(executable: executable, fallbackPath: fallbackPath)
        try Data(script.utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: launcher.path
        )
        return launcher
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launcherScript(executable: String, fallbackPath: String?) -> String {
        var script = "#!/bin/sh\nset -u\n"
        if let fallbackPath, !fallbackPath.isEmpty {
            script += "case \"${PINENTRY_USER_DATA-}\" in\n"
            script += "  \(ArborPinentryEndpoint.prefix)*)\n"
            script += "    exec \(shellQuote(executable)) \(shellQuote(ArborPinentryProcess.argument)) \"$@\"\n"
            script += "    ;;\n"
            script += "  \(remoteEntrypointPrefix)*)\n"
            script += "    entrypoint=\"${PINENTRY_USER_DATA#\(remoteEntrypointPrefix)}\"\n"
            script += "    entrypoint=\"${entrypoint%%:*}\"\n"
            script += "    if [ -n \"$entrypoint\" ]; then exec \"$entrypoint\" \"$@\"; fi\n"
            script += "    ;;\n"
            script += "esac\n"
            script += "exec \(shellQuote(fallbackPath)) \"$@\"\n"
        } else {
            script += "case \"${PINENTRY_USER_DATA-}\" in\n"
            script += "  \(ArborPinentryEndpoint.prefix)*)\n"
            script += "    exec \(shellQuote(executable)) \(shellQuote(ArborPinentryProcess.argument)) \"$@\"\n"
            script += "    ;;\n"
            script += "  \(remoteEntrypointPrefix)*)\n"
            script += "    entrypoint=\"${PINENTRY_USER_DATA#\(remoteEntrypointPrefix)}\"\n"
            script += "    entrypoint=\"${entrypoint%%:*}\"\n"
            script += "    if [ -n \"$entrypoint\" ]; then exec \"$entrypoint\" \"$@\"; fi\n"
            script += "    ;;\n"
            script += "esac\n"
            script += "exec \(shellQuote(executable)) \(shellQuote(ArborPinentryProcess.argument)) \"$@\"\n"
        }
        return script
    }
}

/// External pinentry configuration for GPG agent. The engine owns the
/// gpg-agent.conf backup/atomic-write/reload protocol; this view exposes both
/// the embedded IntelliJ-style helper and the system pinentry fallback.
struct GpgAgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status: GpgAgentStatus?
    @State private var pinentryPath = ""
    @State private var message = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GPG Agent / Pinentry")
                .font(.title3.weight(.semibold))
            Text("Arbor uses the system GPG agent. Configure an external pinentry program, back up the existing agent config, and reload the agent before retrying a signed commit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let status {
                GroupBox("Detected configuration") {
                    VStack(alignment: .leading, spacing: 6) {
                        gpgPathRow("GnuPG home", status.home)
                        gpgPathRow("Agent config", status.configPath)
                        gpgPathRow(
                            "Current pinentry",
                            ArborEmbeddedPinentry.isConfigured(status.pinentryProgram)
                                ? "Arbor embedded"
                                : (status.pinentryProgram ?? "Not configured")
                        )
                        gpgPathRow("Detected default", status.defaultPinentryProgram ?? "Not detected")
                    }
                }
                if !status.available {
                    HStack(alignment: .top, spacing: 8) {
                        Label(
                            "GnuPG is not available. Install GnuPG, then refresh this panel before configuring pinentry.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("GnuPG Downloads") {
                            NSWorkspace.shared.open(GnuPGInstallationGuide.downloadURL)
                        }
                    }
                }
            } else if !message.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    if gnuPGAvailabilityFailure(message)
                        || gitCommitSigningFailureNeedsGPGConfiguration(message) {
                        Button("GnuPG Downloads") {
                            NSWorkspace.shared.open(GnuPGInstallationGuide.downloadURL)
                        }
                    }
                }
            }

            TextField("External pinentry program (optional: use detected default)", text: $pinentryPath)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Choose…", action: choosePinentry)
                Button("Use Detected Default", action: useDetectedDefault)
                    .disabled(status?.defaultPinentryProgram == nil)
                Button("Use Arbor Embedded", action: configureEmbedded)
                    .disabled(isBusy || status?.available == false)
                Spacer()
                Button("Refresh", action: loadStatus)
                    .disabled(isBusy)
                Button("Configure & Reload", action: configure)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || status?.available == false)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Arbor Embedded is selected only for Arbor signing sessions; other GPG callers continue to use the detected system pinentry. Use the system option when GnuPG is managed externally.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: { dismiss() })
            }
        }
        .padding(20)
        .frame(width: 700)
        .onAppear(perform: loadStatus)
    }

    private func gpgPathRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func choosePinentry() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            pinentryPath = url.path
            message = ""
        }
    }

    private func useDetectedDefault() {
        pinentryPath = status?.defaultPinentryProgram ?? ""
        message = ""
    }

    private func loadStatus() {
        isBusy = true
        message = ""
        Task.detached(priority: .userInitiated) {
            do {
                let detected = try gpgAgentStatus()
                await MainActor.run {
                    status = detected
                    if pinentryPath.isEmpty {
                        pinentryPath = detected.pinentryProgram ?? detected.defaultPinentryProgram ?? ""
                    }
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    status = nil
                    message = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }

    private func configure() {
        let selected = pinentryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        message = ""
        Task.detached(priority: .userInitiated) {
            do {
                let updated = try configureGpgAgent(pinentryProgram: selected.isEmpty ? nil : selected)
                await MainActor.run {
                    status = updated
                    pinentryPath = updated.pinentryProgram ?? selected
                    message = "GPG agent configured and reloaded."
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }

    private func configureEmbedded() {
        isBusy = true
        message = ""
        Task.detached(priority: .userInitiated) {
            do {
                let updated = try ArborEmbeddedPinentry.configure()
                await MainActor.run {
                    status = updated
                    pinentryPath = updated.pinentryProgram ?? ArborEmbeddedPinentry.launcherURL.path
                    message = "Arbor embedded pinentry configured and reloaded."
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }
}
