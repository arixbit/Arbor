import Foundation
import CryptoKit
import Network

/// The short-lived endpoint advertised to the embedded pinentry process.
/// Only loopback endpoints are accepted: the token is inherited from a
/// signed Git child process and is not a general-purpose remote service.
struct ArborPinentryEndpoint: Equatable, Sendable {
    static let prefix = "AR_PINENTRY="

    let publicKey: Data
    let host: String
    let port: UInt16

    var token: String {
        Self.prefix + [
            publicKey.base64EncodedString(),
            host,
            String(port)
        ].joined(separator: ":")
    }

    static func parse(_ value: String) -> ArborPinentryEndpoint? {
        let raw = value.hasPrefix(prefix)
            ? String(value.dropFirst(prefix.count))
            : value
        let fields = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let publicKey = Data(base64Encoded: String(fields[0])),
              publicKey.count == 32,
              fields[1] == "127.0.0.1",
              let port = UInt16(fields[2]),
              port > 0 else {
            return nil
        }
        return ArborPinentryEndpoint(publicKey: publicKey, host: String(fields[1]), port: port)
    }
}

/// CryptoKit transport for one pinentry request. Curve25519 avoids the
/// private-key RSA encryption used by the reference JVM helper while keeping
/// the same property: the helper can return a passphrase only to the Arbor
/// process that created the ephemeral session.
enum ArborPinentryCrypto {
    private static let salt = Data("Arbor pinentry v1".utf8)

    private static func key(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data
    ) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    static func encrypt(
        passphrase: String,
        clientPublicKey: Data,
        servicePrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        let sealed = try AES.GCM.seal(
            Data(passphrase.utf8),
            using: key(privateKey: servicePrivateKey, peerPublicKey: clientPublicKey)
        )
        guard let combined = sealed.combined else {
            throw NSError(domain: "Arbor.Pinentry", code: 1)
        }
        return combined.base64EncodedString()
    }

    static func decrypt(
        payload: String,
        servicePublicKey: Data,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> String {
        guard let combined = Data(base64Encoded: payload) else {
            throw NSError(domain: "Arbor.Pinentry", code: 2)
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(
            box,
            using: key(privateKey: clientPrivateKey, peerPublicKey: servicePublicKey)
        )
        guard let passphrase = String(data: plaintext, encoding: .utf8) else {
            throw NSError(domain: "Arbor.Pinentry", code: 3)
        }
        return passphrase
    }
}

/// The main Arbor process owns the UI prompt. The embedded pinentry helper
/// connects here over a short-lived loopback socket while GPG is signing.
final class ArborPinentryService: @unchecked Sendable {
    static let shared = ArborPinentryService()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.arbor.pinentry.service")
    private var listener: NWListener?
    private var activeToken: String?
    private var sessionUsers = 0

    func startSession() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let activeToken {
            sessionUsers += 1
            return activeToken
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 0)!
        )
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, servicePrivateKey: privateKey)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw NSError(
                domain: "Arbor.Pinentry",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Timed out starting the pinentry service."]
            )
        }
        guard listener.state == .ready,
              let port = listener.port?.rawValue,
              port > 0 else {
            listener.cancel()
            throw NSError(
                domain: "Arbor.Pinentry",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The pinentry service could not bind a loopback port."]
            )
        }

        let endpoint = ArborPinentryEndpoint(
            publicKey: privateKey.publicKey.rawRepresentation,
            host: "127.0.0.1",
            port: port
        )
        self.listener = listener
        self.activeToken = endpoint.token
        self.sessionUsers = 1
        return endpoint.token
    }

    /// Returns true only when the last operation released the session.
    @discardableResult
    func stopSession() -> Bool {
        lock.lock()
        guard activeToken != nil else {
            lock.unlock()
            return false
        }
        sessionUsers = max(0, sessionUsers - 1)
        guard sessionUsers == 0 else {
            lock.unlock()
            return false
        }
        let listener = self.listener
        self.listener = nil
        self.activeToken = nil
        lock.unlock()
        listener?.cancel()
        return true
    }

    private func accept(
        _ connection: NWConnection,
        servicePrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        connection.start(queue: queue)
        ArborPinentrySocket.receiveLine(connection: connection, buffer: Data()) { [weak self] line in
            self?.handle(
                line: line,
                connection: connection,
                servicePrivateKey: servicePrivateKey
            )
        }
    }

    private func handle(
        line: Data,
        connection: NWConnection,
        servicePrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        let request = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = request.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3,
              fields[0] == "GETPIN",
              let clientPublicKey = Data(base64Encoded: String(fields[1])) else {
            ArborPinentrySocket.send("ERR 83886181 malformed request", on: connection) {
                connection.cancel()
            }
            return
        }

        let description = ArborPinentryProtocol.unescape(String(fields[2]))
        Task { @MainActor in
            guard let passphrase = ArborPinentryPrompt.request(
                description: description,
                title: "GPG Passphrase",
                prompt: "Passphrase",
                okTitle: "OK",
                cancelTitle: "Cancel",
                errorMessage: ""
            ) else {
                ArborPinentrySocket.send("ERR 83886179 canceled", on: connection) {
                    connection.cancel()
                }
                return
            }

            do {
                let encrypted = try ArborPinentryCrypto.encrypt(
                    passphrase: passphrase,
                    clientPublicKey: clientPublicKey,
                    servicePrivateKey: servicePrivateKey
                )
                ArborPinentrySocket.send("D \(encrypted)\nOK", on: connection) {
                    connection.cancel()
                }
            } catch {
                ArborPinentrySocket.send("ERR 83886181 encryption failed", on: connection) {
                    connection.cancel()
                }
            }
        }
    }
}

/// Blocking socket helpers are isolated from the AppKit prompt. The helper
/// process is synchronous by design because GPG waits for the pinentry reply.
enum ArborPinentrySocket {
    private static let queue = DispatchQueue(label: "com.arbor.pinentry.socket")

    struct Response {
        let line: Data
        let clientPrivateKey: Curve25519.KeyAgreement.PrivateKey
    }

    static func send(
        _ value: String,
        on connection: NWConnection,
        completion: @escaping () -> Void
    ) {
        connection.send(
            content: Data(value.utf8),
            completion: .contentProcessed { _ in completion() }
        )
    }

    static func receiveLine(
        connection: NWConnection,
        buffer: Data,
        completion: @escaping (Data) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { data, _, isComplete, _ in
            var buffer = buffer
            if let data {
                buffer.append(data)
                if let newline = buffer.firstIndex(of: 0x0A) {
                    completion(Data(buffer[..<newline]))
                    return
                }
            }
            if isComplete {
                completion(buffer)
            } else {
                receiveLine(connection: connection, buffer: buffer, completion: completion)
            }
        }
    }

    static func request(
        endpoint: ArborPinentryEndpoint,
        description: String
    ) -> Response? {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
        let clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response: Data?
        var finished = false

        func finish(_ value: Data?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            response = value
            lock.unlock()
            semaphore.signal()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GETPIN \(clientPrivateKey.publicKey.rawRepresentation.base64EncodedString()) \(ArborPinentryProtocol.escape(description))\n"
                connection.send(
                    content: Data(request.utf8),
                    completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    }
                )
                receiveLine(connection: connection, buffer: Data()) { line in
                    finish(line)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            connection.cancel()
            return nil
        }
        connection.cancel()
        guard let response else { return nil }
        return Response(line: response, clientPrivateKey: clientPrivateKey)
    }
}
