import AppKit

enum ArborPinentryClientOutcome {
    case unavailable
    case passphrase(String)
    case canceled
}

enum ArborPinentryClient {
    static func request(description: String) -> ArborPinentryClientOutcome {
        guard let value = ProcessInfo.processInfo.environment["PINENTRY_USER_DATA"],
              let endpoint = ArborPinentryEndpoint.parse(value),
              let exchange = ArborPinentrySocket.request(endpoint: endpoint, description: description),
              let response = String(data: exchange.line, encoding: .utf8) else {
            return .unavailable
        }

        if response.hasPrefix("ERR") {
            return response.localizedCaseInsensitiveContains("cancel") ? .canceled : .unavailable
        }
        guard response.hasPrefix("D ") else { return .unavailable }
        let payload = String(response.dropFirst(2))
        do {
            let passphrase = try ArborPinentryCrypto.decrypt(
                payload: payload,
                servicePublicKey: endpoint.publicKey,
                clientPrivateKey: exchange.clientPrivateKey
            )
            return .passphrase(passphrase)
        } catch {
            return .unavailable
        }
    }
}

/// Shared AppKit prompt used by the main service and the standalone helper.
@MainActor
enum ArborPinentryPrompt {
    static func request(
        description: String,
        title: String,
        prompt: String,
        okTitle: String,
        cancelTitle: String,
        errorMessage: String
    ) -> String? {
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title.isEmpty ? "GPG Passphrase" : title
        alert.informativeText = [description, errorMessage]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = prompt.isEmpty ? "Passphrase" : prompt
        alert.accessoryView = field
        alert.addButton(withTitle: okTitle.isEmpty ? "OK" : okTitle)
        alert.addButton(withTitle: cancelTitle.isEmpty ? "Cancel" : cancelTitle)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Minimal native pinentry helper used by the optional embedded GPG agent
/// launcher. GPG talks to this process over the standard pinentry
/// stdin/stdout protocol. When `PINENTRY_USER_DATA` is present, GETPIN is
/// proxied to the main process over the encrypted loopback session; otherwise
/// the helper owns the prompt as a standalone fallback. Neither path persists
/// the passphrase.
@MainActor
final class ArborPinentryProcess {
    nonisolated static let argument = "--arbor-pinentry"

    static var isInvocation: Bool {
        CommandLine.arguments.contains(argument)
    }

    private static var activeProcess: ArborPinentryProcess?

    static func startIfRequested() -> Bool {
        guard isInvocation else { return false }
        let process = ArborPinentryProcess()
        activeProcess = process
        process.start()
        return true
    }

    private let outputLock = NSLock()
    private var description = "Enter the passphrase to unlock the signing key."
    private var title = "GPG Passphrase"
    private var prompt = "Passphrase"
    private var okTitle = "OK"
    private var cancelTitle = "Cancel"
    private var errorMessage = ""
    private var isFinished = false

    private func start() {
        send("OK Pleased to meet you")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                Task { @MainActor [weak self] in
                    self?.handle(line)
                }
            }
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
    }

    private func handle(_ line: String) {
        guard !isFinished else { return }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = parts.first.map(String.init) ?? ""
        let value = parts.count == 2 ? String(parts[1]) : ""

        switch command {
        case "SETDESC":
            description = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETTITLE":
            title = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETPROMPT":
            prompt = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETOK":
            okTitle = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETCANCEL":
            cancelTitle = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "SETERROR":
            errorMessage = ArborPinentryProtocol.unescape(value)
            send("OK")
        case "GETPIN":
            requestPassphrase()
        case "CONFIRM":
            requestConfirmation()
        case "CANCEL", "RESET":
            send("OK")
        case "OPTION", "SETKEYINFO", "SETCACHED", "SETNOTOK", "SETREPEAT", "SETREPEATERROR":
            send("OK")
        case "GETINFO":
            sendInfo(value)
        case "BYE":
            send("OK closing connection")
            finish()
        case "", "COMMENT", "MESSAGE":
            send("OK")
        default:
            send("ERR 83886181 unknown command <\(line)>")
        }
    }

    private func requestPassphrase() {
        switch ArborPinentryClient.request(description: description) {
        case let .passphrase(passphrase):
            send("D \(ArborPinentryProtocol.escape(passphrase))")
            send("OK")
        case .canceled:
            send("ERR 83886179 canceled")
        case .unavailable:
            guard let passphrase = ArborPinentryPrompt.request(
                description: description,
                title: title,
                prompt: prompt,
                okTitle: okTitle,
                cancelTitle: cancelTitle,
                errorMessage: errorMessage
            ) else {
                send("ERR 83886179 canceled")
                return
            }
            send("D \(ArborPinentryProtocol.escape(passphrase))")
            send("OK")
        }
    }

    private func requestConfirmation() {
        NSApp.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title.isEmpty ? "Confirm GPG operation" : title
        alert.informativeText = description
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            send("OK")
        } else {
            send("ERR 83886179 canceled")
        }
        NSApp.setActivationPolicy(.prohibited)
    }

    private func sendInfo(_ value: String) {
        switch value {
        case "pid":
            send("D \(ProcessInfo.processInfo.processIdentifier)")
            send("OK")
        case "flavor":
            send("D Arbor")
            send("OK")
        case "version":
            send("D 1.0")
            send("OK")
        default:
            send("OK")
        }
    }

    private func send(_ line: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        NSApp.terminate(nil)
    }
}

enum ArborPinentryProtocol {
    static func escape(_ value: String) -> String {
        value.utf8.reduce(into: "") { result, byte in
            if byte == 0x25 || byte < 0x20 || byte > 0x7E {
                result += String(format: "%%%02X", byte)
            } else {
                result.append(Character(UnicodeScalar(byte)))
            }
        }
    }

    static func unescape(_ value: String) -> String {
        var bytes: [UInt8] = []
        let input = Array(value.utf8)
        var index = 0
        while index < input.count {
            if input[index] == 0x25,
               index + 2 < input.count,
               let high = hexValue(input[index + 1]),
               let low = hexValue(input[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(input[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
