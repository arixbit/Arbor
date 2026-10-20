import XCTest
import Foundation
import CryptoKit
@testable import Arbor

extension CompareSelectionTests {

    func testEmbeddedPinentryProtocolEscapesAndUnescapesGpgData() {
        let original = "line one\n百分号 %\r"
        let encoded = ArborPinentryProtocol.escape(original)

        XCTAssertEqual(encoded, "line one%0A%E7%99%BE%E5%88%86%E5%8F%B7 %25%0D")
        XCTAssertEqual(ArborPinentryProtocol.unescape(encoded), original)
    }

    func testPinentryEndpointAndEncryptedPassphraseRoundTrip() throws {
        let serviceKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let endpoint = ArborPinentryEndpoint(
            publicKey: serviceKey.publicKey.rawRepresentation,
            host: "127.0.0.1",
            port: 41_237
        )

        XCTAssertEqual(ArborPinentryEndpoint.parse(endpoint.token), endpoint)
        XCTAssertNil(ArborPinentryEndpoint.parse("AR_PINENTRY=not-a-key:127.0.0.1:41237"))

        let encrypted = try ArborPinentryCrypto.encrypt(
            passphrase: "päss phrase % with spaces",
            clientPublicKey: clientKey.publicKey.rawRepresentation,
            servicePrivateKey: serviceKey
        )
        XCTAssertEqual(
            try ArborPinentryCrypto.decrypt(
                payload: encrypted,
                servicePublicKey: serviceKey.publicKey.rawRepresentation,
                clientPrivateKey: clientKey
            ),
            "päss phrase % with spaces"
        )
    }

    func testEmbeddedPinentryLauncherShellQuotesExecutablePaths() {
        XCTAssertEqual(
            ArborEmbeddedPinentry.shellQuote("/Users/me/O'Reilly/Arbor.app"),
            "'/Users/me/O'\\''Reilly/Arbor.app'"
        )

        let script = ArborEmbeddedPinentry.launcherScript(
            executable: "/Applications/Arbor.app/Contents/MacOS/Arbor",
            fallbackPath: "/opt/homebrew/bin/pinentry"
        )
        XCTAssertTrue(script.contains("--arbor-pinentry"))
        XCTAssertTrue(script.contains("exec '/opt/homebrew/bin/pinentry' \"$@\""))
        XCTAssertTrue(script.contains("case \"${PINENTRY_USER_DATA-}\" in"))
        XCTAssertTrue(script.contains("AR_PINENTRY=*)"))
        XCTAssertTrue(script.contains("IJ_PINENTRY_ENTRYPOINT=*)"))
        XCTAssertTrue(script.contains("entrypoint=\"${entrypoint%%:*}\""))
        XCTAssertFalse(script.contains("status=$?"))
    }

    func testEmbeddedPinentryLauncherRoutesOnlyArborSessionsToHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arbor Pinentry Launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helper = root.appendingPathComponent("helper")
        let fallback = root.appendingPathComponent("fallback")
        let launcher = root.appendingPathComponent("launcher")
        let helperOutput = root.appendingPathComponent("helper-output")
        let fallbackOutput = root.appendingPathComponent("fallback-output")

        try writeExecutableScript(
            at: helper,
            body: "touch \(ArborEmbeddedPinentry.shellQuote(helperOutput.path))\nprintf 'helper:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(helperOutput.path))\nexit 7\n"
        )
        try writeExecutableScript(
            at: fallback,
            body: "printf 'fallback:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(fallbackOutput.path))\n"
        )
        let script = ArborEmbeddedPinentry.launcherScript(
            executable: helper.path,
            fallbackPath: fallback.path
        )
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: launcher.path
        )

        let noSession = try runLauncher(launcher, environment: [:])
        XCTAssertEqual(noSession.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperOutput.path))
        XCTAssertEqual(
            try String(contentsOf: fallbackOutput, encoding: .utf8),
            "fallback:launcher-test-argument\n"
        )

        try FileManager.default.removeItem(at: fallbackOutput)
        let arborSession = try runLauncher(
            launcher,
            environment: ["PINENTRY_USER_DATA": "AR_PINENTRY=test-token"]
        )
        XCTAssertEqual(arborSession.terminationStatus, 7)
        XCTAssertEqual(
            try String(contentsOf: helperOutput, encoding: .utf8),
            "helper:--arbor-pinentry launcher-test-argument\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackOutput.path))
    }

    func testEmbeddedPinentryLauncherForwardsRemoteEntrypointBeforeFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arbor Remote Pinentry Launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = root.appendingPathComponent("remote entrypoint")
        let fallback = root.appendingPathComponent("fallback")
        let launcher = root.appendingPathComponent("launcher")
        let remoteOutput = root.appendingPathComponent("remote-output")
        let fallbackOutput = root.appendingPathComponent("fallback-output")

        try writeExecutableScript(
            at: remote,
            body: "printf 'remote:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(remoteOutput.path))\nexit 9\n"
        )
        try writeExecutableScript(
            at: fallback,
            body: "printf 'fallback:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(fallbackOutput.path))\n"
        )
        let script = ArborEmbeddedPinentry.launcherScript(
            executable: root.appendingPathComponent("Arbor.app").path,
            fallbackPath: fallback.path
        )
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: launcher.path
        )

        let result = try runLauncher(
            launcher,
            environment: [
                "PINENTRY_USER_DATA": "\(ArborEmbeddedPinentry.remoteEntrypointPrefix)\(remote.path):public-key:127.0.0.1:1234"
            ]
        )
        XCTAssertEqual(result.terminationStatus, 9)
        XCTAssertEqual(
            try String(contentsOf: remoteOutput, encoding: .utf8),
            "remote:launcher-test-argument\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackOutput.path))

        let emptyEntrypoint = try runLauncher(
            launcher,
            environment: [
                "PINENTRY_USER_DATA": "\(ArborEmbeddedPinentry.remoteEntrypointPrefix):public-key:127.0.0.1:1234"
            ]
        )
        XCTAssertEqual(emptyEntrypoint.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: fallbackOutput, encoding: .utf8),
            "fallback:launcher-test-argument\n"
        )
    }

    private func writeExecutableScript(at url: URL, body: String) throws {
        try Data("#!/bin/sh\nset -u\n\(body)".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func runLauncher(
        _ launcher: URL,
        environment: [String: String]
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [launcher.path, "launcher-test-argument"]
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.removeValue(forKey: "PINENTRY_USER_DATA")
        process.environment = processEnvironment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        return process
    }

    func testGpgSigningFailureClassifierOffersConfigurationOnlyForGpgFailures() {
        XCTAssertTrue(
            gitCommitSigningFailureNeedsGPGConfiguration(
                "error: gpg failed to sign the data"
            )
        )
        XCTAssertTrue(
            gitCommitSigningFailureNeedsGPGConfiguration(
                "gpg: signing failed: No secret key"
            )
        )
        XCTAssertFalse(
            gitCommitSigningFailureNeedsGPGConfiguration(
                "ssh-keygen signing failed for the configured key"
            )
        )
        XCTAssertTrue(
            gnuPGAvailabilityFailure("cannot start gpgconf: No such file or directory")
        )
        XCTAssertTrue(
            gnuPGAvailabilityFailure("cannot resolve GnuPG home directory")
        )
        XCTAssertFalse(gnuPGAvailabilityFailure("gpgconf status command failed"))
    }

    func testOpenGpgAgentSettingsActionRequestRoundTrips() throws {
        let request = ArborVCSActionRequest(
            kind: .openGpgAgentSettings,
            projectPath: "/project",
            rootPath: nil,
            shelfName: ""
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            GnuPGInstallationGuide.downloadURL.absoluteString,
            "https://gnupg.org/download/"
        )
    }

    func testCredentialPersistenceNeverStoresSSHPassphrase() {
        XCTAssertTrue(
            credentialResponseShouldSaveToKeychain(
                kind: .usernamePassword,
                requested: true
            )
        )
        XCTAssertFalse(
            credentialResponseShouldSaveToKeychain(
                kind: .passphrase,
                requested: true
            )
        )
        XCTAssertFalse(
            credentialResponseShouldSaveToKeychain(
                kind: .usernamePassword,
                requested: false
            )
        )
    }

    func testAggregateAuthenticationFailureMessageMatchesSingleRootClassification() {
        XCTAssertTrue(arborAuthenticationFailureMessage("fatal: Authentication failed for 'https://github.com/acme/repo.git'"))
        XCTAssertTrue(arborAuthenticationFailureMessage("fatal: could not read Username for 'https://github.com/acme/repo.git'"))
        XCTAssertTrue(arborAuthenticationFailureMessage("git@github.com: Permission denied (publickey)."))
        XCTAssertTrue(arborAuthenticationFailureMessage("remote returned HTTP 401"))
        XCTAssertFalse(arborAuthenticationFailureMessage("remote rejected the update because it is not a fast-forward"))
        XCTAssertFalse(arborAuthenticationFailureMessage("credential helper returned an empty response"))
    }
}
