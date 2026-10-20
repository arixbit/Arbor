import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct GitSSHSettingsView: View {
    @Binding var command: String
    @Binding var knownHostsFile: String
    @Binding var identityFile: String
    @Binding var hostKeyPolicy: SshHostKeyPolicy
    @Binding var authMethod: SshAuthMethod
    @Binding var credentialHelperConfig: String
    let credentialHelpers: [CredentialHelperInfo]
    let onRefreshCredentialHelpers: () -> Void
    let sshAgentDiagnostics: SshAgentDiagnostics?
    let onRefreshSSHAgentDiagnostics: () -> Void
    let lastSuccessfulAuthentications: [SSHAuthenticationRecord]
    let onClearLastSuccessfulAuthentications: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git SSH Command")
                .font(.title3)
                .bold()
            TextField("e.g. ssh -i ~/.ssh/id_ed25519", text: $command)
                .textFieldStyle(.roundedBorder)
            Text("Stored as this repository's core.sshCommand. Leave it empty to use the default SSH configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The value may include SSH options, such as -i, -F, or -o.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Host key verification")
                .font(.headline)
            Picker("Host key verification", selection: $hostKeyPolicy) {
                Text("Strict (recommended)").tag(SshHostKeyPolicy.strict)
                Text("Accept new keys").tag(SshHostKeyPolicy.acceptNew)
                Text("Ask before trusting").tag(SshHostKeyPolicy.ask)
                Text("Do not verify (unsafe)").tag(SshHostKeyPolicy.noCheck)
            }
            .pickerStyle(.segmented)
            Text("Strict rejects unknown or changed host keys; Ask before trusting shows the host fingerprint; Accept new keys records a first-seen key; Do not verify disables host-key protection.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hostKeyPolicy == .noCheck {
                Label("Host-key verification is disabled for this repository.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                TextField("Known hosts file (optional)", text: $knownHostsFile)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { chooseFile { knownHostsFile = $0 } }
            }
            Picker("Authentication method", selection: $authMethod) {
                Text("Automatic").tag(SshAuthMethod.auto)
                Text("SSH key only").tag(SshAuthMethod.publicKey)
                Text("Password / keyboard-interactive").tag(SshAuthMethod.password)
            }
            Text("Automatic uses the OpenSSH default order. SSH key only restricts authentication to public keys; password mode enables password and keyboard-interactive prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Identity file (optional)", text: $identityFile)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { chooseFile { identityFile = $0 } }
            }
            Text("An identity file enables IdentitiesOnly so OpenSSH does not try unrelated agent keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("SSH agent")
                    .font(.headline)
                Spacer()
                Button("Refresh", action: onRefreshSSHAgentDiagnostics)
                    .controlSize(.small)
            }
            if let diagnostics = sshAgentDiagnostics {
                HStack(spacing: 7) {
                    Image(systemName: diagnostics.state.systemImage)
                        .foregroundStyle(diagnostics.state.tint)
                    Text(diagnostics.state.displayTitle)
                    Spacer()
                    if diagnostics.identityCount > 0 {
                        Text("\(diagnostics.identityCount) identities")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !diagnostics.socketPath.isEmpty {
                    Text("Socket: \(diagnostics.socketPath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("SSH agent diagnostics are not loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Refresh runs the read-only ssh-add -l probe. It never adds, removes, unlocks, or stores agent keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Local credential.helper values")
                .font(.headline)
            Text("One helper per line. These values are stored in this repository's local Git config; leave empty to remove local overrides.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $credentialHelperConfig)
                .font(.system(.body, design: .monospaced))
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack {
                Text("Credential Helpers")
                    .font(.headline)
                Spacer()
                Button("Refresh", action: onRefreshCredentialHelpers)
                    .controlSize(.small)
            }
            if credentialHelpers.isEmpty {
                Text("No repository or user credential helpers are configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(credentialHelpers.enumerated()), id: \.offset) { _, helper in
                    HStack(spacing: 7) {
                        Image(systemName: helper.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(helper.available ? .green : .orange)
                        Text(helper.name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(helper.available ? "Available" : "Not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("The diagnostic list includes repository and user helpers. Available means the executable is present; actual credential success is confirmed only by a successful Git operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Last successful SSH authentications")
                    .font(.headline)
                Spacer()
                Button("Clear", action: onClearLastSuccessfulAuthentications)
                    .controlSize(.small)
                    .disabled(lastSuccessfulAuthentications.isEmpty)
            }
            if lastSuccessfulAuthentications.isEmpty {
                Text("No prompt-based SSH authentication has succeeded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lastSuccessfulAuthentications) { record in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text(record.key)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(record.method == "publickey" ? "SSH key" : "Password")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Only the user@host and method are stored; credentials and SSH agent secrets are never saved here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseFile(_ onSelect: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
    }
}

private extension SshAgentState {
    var displayTitle: String {
        switch self {
        case .notConfigured:
            return String(localized: "SSH agent is not configured")
        case .unreachable:
            return String(localized: "SSH agent is not reachable")
        case .noIdentities:
            return String(localized: "SSH agent is reachable, but has no identities")
        case .ready:
            return String(localized: "SSH agent is ready")
        case .error:
            return String(localized: "SSH agent probe failed")
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .noIdentities:
            return "minus.circle.fill"
        case .notConfigured:
            return "questionmark.circle"
        case .unreachable, .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            return .green
        case .noIdentities, .notConfigured:
            return .secondary
        case .unreachable, .error:
            return .orange
        }
    }
}
