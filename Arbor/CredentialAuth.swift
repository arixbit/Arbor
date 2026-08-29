import SwiftUI
import AppKit

extension Notification.Name {
    static let arborGitCredentialHelperSettingChanged = Notification.Name(
        "arbor.git.useCredentialHelper.changed"
    )
}

/// AUTH-001：Swift 侧凭证交互层。
///
/// `CredentialAuthController` 持有引擎的 `CredentialBroker` 并注入
/// `CredentialRequestHandlerImpl`：
/// 1. Keychain 静默命中（已知 username）→ 直接返回，无 UI；
/// 2. 未命中 → 主线程弹 `CredentialDialogView`（引擎的 askpass 服务线程
///    阻塞等待，主线程不被阻塞）；
/// 3. 用户勾选保存 → 写入 Keychain；
/// 4. 取消 → 引擎把操作分类为 Cancelled（UI 显示「已取消」而非 generic error）。
///
/// 凭证只存在于内存与 Keychain，不经过日志（引擎侧脱敏兜底）。
/// SSH 最近成功方式只保存 `user@host -> method`，不保存任何 secret。

struct SSHAuthenticationRecord: Identifiable, Equatable {
    let key: String
    let method: String

    var id: String { key }
}

func credentialResponseShouldSaveToKeychain(
    kind: CredentialKind,
    requested: Bool
) -> Bool {
    requested && kind == .usernamePassword
}

/// 对应 IntelliJ SSHConnectionSettings 的 last-successful authentication 状态。
/// 这里保存的是非敏感的连接偏好，不是凭证。
final class SSHAuthenticationStore: @unchecked Sendable {
    static let shared = SSHAuthenticationStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "ssh.lastSuccessfulAuthentication"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func method(username: String, host: String) -> String? {
        let key = Self.key(username: username, host: host)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return (defaults.dictionary(forKey: storageKey) as? [String: String])?[key]
    }

    func records() -> [SSHAuthenticationRecord] {
        lock.lock()
        defer { lock.unlock() }
        let values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        return values.keys.sorted().compactMap { key in
            guard let method = values[key], !method.isEmpty else { return nil }
            return SSHAuthenticationRecord(key: key, method: method)
        }
    }

    func set(method: String, username: String, host: String) {
        let key = Self.key(username: username, host: host)
        guard !key.isEmpty, method == "publickey" || method == "password" else { return }
        lock.lock()
        defer { lock.unlock() }
        var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        values[key] = method
        defaults.set(values, forKey: storageKey)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private static func key(username: String, host: String) -> String {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !host.isEmpty,
              !username.contains("\n"), !username.contains("\r"),
              !host.contains("\n"), !host.contains("\r") else { return "" }
        return "\(username)@\(host)"
    }
}

/// IntelliJ's DvcsRememberedInputs equivalent for Git HTTP usernames.
/// Usernames are not secrets, but the key is the complete remote URL so two
/// accounts on the same host do not overwrite one another.
final class GitRememberedUsernameStore: @unchecked Sendable {
    static let shared = GitRememberedUsernameStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "git.rememberedUsernames.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func username(for remoteURL: String) -> String? {
        let key = Self.normalizedRemoteURL(remoteURL)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let value = (defaults.dictionary(forKey: storageKey) as? [String: String])?[key]
        return value?.isEmpty == false ? value : nil
    }

    func setUsername(_ username: String, for remoteURL: String) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalizedRemoteURL(remoteURL)
        guard !username.isEmpty, !key.isEmpty,
              !username.contains("\n"), !username.contains("\r") else { return }
        lock.lock()
        defer { lock.unlock() }
        var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        values[key] = username
        defaults.set(values, forKey: storageKey)
    }

    func removeUsername(for remoteURL: String) {
        let key = Self.normalizedRemoteURL(remoteURL)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        values.removeValue(forKey: key)
        defaults.set(values, forKey: storageKey)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private static func normalizedRemoteURL(_ remoteURL: String) -> String {
        let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { return "" }
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            components.host = host.lowercased()
        }
        return components.string ?? value
    }
}

/// 从引擎 askpass 线程被访问（resolve 等待信号量），标记为 Sendable。
final class CredentialAuthController: ObservableObject, @unchecked Sendable {
    /// 待展示的请求；非 nil 时 ContentView 弹对话框。
    @Published var request: CredentialRequest?
    @Published var isPresented = false

    let broker: CredentialBroker
    private let keychain: KeychainStore
    private let sshAuthenticationStore: SSHAuthenticationStore
    private let rememberedUsernameStore: GitRememberedUsernameStore
    private var handler: CredentialRequestHandlerImpl?
    private var credentialHelperSettingObserver: NSObjectProtocol?
    /// 引擎线程的等待信号量；对话框关闭时由用户动作触发。
    private var semaphore: DispatchSemaphore?
    private var pending: CredentialResponse?

    init(
        keychain: KeychainStore = .shared,
        sshAuthenticationStore: SSHAuthenticationStore = .shared,
        rememberedUsernameStore: GitRememberedUsernameStore = .shared
    ) {
        self.broker = CredentialBroker()
        self.keychain = keychain
        self.sshAuthenticationStore = sshAuthenticationStore
        self.rememberedUsernameStore = rememberedUsernameStore
        self.broker.setUseCredentialHelper(
            enabled: UserDefaults.standard.bool(forKey: "arbor.git.useCredentialHelper")
        )
        self.credentialHelperSettingObserver = NotificationCenter.default.addObserver(
            forName: .arborGitCredentialHelperSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let enabled = notification.object as? Bool else { return }
            self?.broker.setUseCredentialHelper(enabled: enabled)
        }
    }

    deinit {
        if let observer = credentialHelperSettingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 确保 handler 已注入（幂等；ContentView onAppear 与首次请求时调用）。
    func ensureInstalled() {
        guard handler == nil else { return }
        let handler = CredentialRequestHandlerImpl(controller: self)
        self.handler = handler
        broker.setHandler(handler: handler)
    }

    /// 引擎线程调用：Keychain 命中则立即返回，否则弹框等待用户决定。
    func resolve(_ req: CredentialRequest) -> CredentialResponse {
        var request = req
        if request.kind == .usernamePassword, request.username.isEmpty,
           let remembered = rememberedUsernameStore.username(for: request.remoteUrl) {
            request.username = remembered
        }
        // Keychain 静默路径：已知用户名时按 (host, username) 查找。
        // IntelliJ forgets a credential after an authentication failure and
        // asks again. A retry request must therefore bypass the stale
        // Keychain value, even when Git supplied the same username.
        if request.attempt <= 1, request.kind == .usernamePassword, !request.username.isEmpty {
            if let secret = try? keychain.gitCredential(host: request.host, username: request.username),
               !secret.isEmpty {
                return CredentialResponse(decision: .provide(
                    username: request.username,
                    secret: secret,
                    saveToKeychain: false
                ))
            }
        }
        // IntelliJ's SILENT authentication mode may use remembered
        // credentials but must never turn a background incoming check into a
        // credential dialog.  Let the engine classify this as an auth
        // failure rather than a user cancellation.
        if !request.allowInteraction {
            return CredentialResponse(decision: .cancel)
        }
        // 弹框路径：信号量阻塞引擎线程；UI 在主线程。
        let semaphore = DispatchSemaphore(value: 0)
        self.semaphore = semaphore
        DispatchQueue.main.async {
            self.request = request
            self.isPresented = true
        }
        semaphore.wait()
        let response = pending ?? CredentialResponse(decision: .cancel)
        pending = nil
        return response
    }

    func userProvided(username: String, secret: String, save: Bool) {
        // SSH passphrases are not Git HTTP credentials. Never place them in
        // the git:<host>:<username> Keychain namespace.
        let request = request
        let shouldSave = request.map {
            credentialResponseShouldSaveToKeychain(kind: $0.kind, requested: save)
        } ?? false
        if let request, request.kind == .usernamePassword {
            rememberedUsernameStore.setUsername(username, for: request.remoteUrl)
        }
        if shouldSave, !username.isEmpty, !secret.isEmpty {
            if let host = request?.host {
                try? keychain.setGitCredential(secret: secret, host: host, username: username)
            }
        }
        let response = CredentialResponse(decision: .provide(
            username: username,
            secret: secret,
            saveToKeychain: shouldSave
        ))
        finish(response)
    }

    func userCancelled() {
        finish(CredentialResponse(decision: .cancel))
    }

    func userAcceptedHostKey() {
        finish(CredentialResponse(decision: .provide(
            username: "",
            secret: "yes",
            saveToKeychain: false
        )))
    }

    func userRejectedHostKey() {
        finish(CredentialResponse(decision: .provide(
            username: "",
            secret: "no",
            saveToKeychain: false
        )))
    }

    /// Mirrors GitHttpGuiAuthenticator.forgetPassword after an authentication
    /// failure. The remembered username remains useful; only the secret is
    /// removed from the host/user Keychain entry.
    func recordAuthenticationFailure(_ request: CredentialRequest) {
        guard request.kind == .usernamePassword else { return }
        let username = request.username.isEmpty
            ? (rememberedUsernameStore.username(for: request.remoteUrl) ?? "")
            : request.username
        guard !username.isEmpty else { return }
        try? keychain.deleteGitCredential(host: request.host, username: username)
    }

    func lastSuccessfulMethod(for request: CredentialRequest) -> String? {
        let prompt = request.prompt.lowercased()
        let isSSH = request.kind == .passphrase || prompt.contains("'s password")
        guard isSSH else { return nil }
        return sshAuthenticationStore.method(username: request.username, host: request.host)
    }

    func recordAuthenticationSuccess(_ success: AuthenticationSuccess) {
        sshAuthenticationStore.set(
            method: success.method,
            username: success.username,
            host: success.host
        )
    }

    func sshAuthenticationRecords() -> [SSHAuthenticationRecord] {
        sshAuthenticationStore.records()
    }

    func clearSSHAuthenticationRecords() {
        sshAuthenticationStore.removeAll()
    }

    private func finish(_ response: CredentialResponse) {
        pending = response
        request = nil
        isPresented = false
        semaphore?.signal()
        semaphore = nil
    }
}

/// uniffi 回调实现：引擎的 askpass 服务线程调用，绝不能直接碰 UI。
private final class CredentialRequestHandlerImpl: CredentialRequestHandler {
    private let controller: CredentialAuthController

    init(controller: CredentialAuthController) {
        self.controller = controller
    }

    func onCredentialRequest(request: CredentialRequest) -> CredentialResponse {
        controller.resolve(request)
    }

    func onAuthenticationSucceeded(success: AuthenticationSuccess) {
        controller.recordAuthenticationSuccess(success)
    }

    func onAuthenticationFailed(request: CredentialRequest) {
        controller.recordAuthenticationFailure(request)
    }
}

/// 认证对话框：host、username、secret、保存开关、取消。
struct CredentialDialogView: View {
    @ObservedObject var controller: CredentialAuthController
    @State private var username = ""
    @State private var secret = ""
    @State private var saveToKeychain = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(hostLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, 4)

            if let previousError = controller.request?.previousError,
               !previousError.isEmpty {
                Label(
                    "Authentication failed. Enter the credentials again.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.red)
            }

            if controller.request?.kind == .hostKey {
                Text("SSH host key verification is required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Review the host key fingerprint before accepting this connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(controller.request?.prompt ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                HStack {
                    Spacer()
                    Button("Reject") { controller.userRejectedHostKey() }
                        .keyboardShortcut(.cancelAction)
                    Button("Accept") { controller.userAcceptedHostKey() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            } else if controller.request?.kind == .passphrase {
                Text("SSH 私钥需要解锁口令（passphrase）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SecureField("Passphrase", text: $secret)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password or Token", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                Toggle(isOn: $saveToKeychain) {
                    Text("Save to Keychain").font(.callout)
                }
            }

            if let request = controller.request,
               let method = controller.lastSuccessfulMethod(for: request) {
                Text("Last successful authentication: \(method == "publickey" ? "SSH key" : "Password")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.request?.kind != .hostKey {
                HStack {
                    Spacer()
                    Button("Cancel") { controller.userCancelled() }
                        .keyboardShortcut(.cancelAction)
                    Button(controller.request?.kind == .passphrase ? "Unlock" : "Log In") {
                        let user = username.isEmpty ? (controller.request?.username ?? "") : username
                        controller.userProvided(username: user, secret: secret, save: saveToKeychain)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(secret.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            username = controller.request?.username ?? ""
            secret = ""
            saveToKeychain = true
        }
    }

    private var title: String {
        switch controller.request?.kind {
        case .hostKey:
            return "SSH Host Key Verification"
        case .passphrase:
            return "SSH Key Passphrase"
        default:
            return "Git Authentication Required"
        }
    }

    private var hostLine: String {
        guard let request = controller.request else { return "" }
        let kind: String
        switch request.kind {
        case .hostKey:
            kind = "SSH host"
        case .passphrase:
            kind = "SSH key"
        default:
            kind = "Git remote"
        }
        return "\(kind) · \(request.host)\(request.attempt > 1 ? " · retry \(request.attempt)" : "")"
    }
}
