import XCTest
@testable import Arbor

final class KeychainStoreTests: XCTestCase {
    func testTokenRoundTripAndDelete() throws {
        let owner = "test-owner-\(UUID().uuidString)"
        let store = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        defer { try? store.deleteToken(forOwner: owner) }

        XCTAssertNil(try store.token(forOwner: owner))
        try store.setToken("test-token-value", forOwner: owner)
        XCTAssertEqual(try store.token(forOwner: owner), "test-token-value")
        try store.setToken("updated-token-value", forOwner: owner)
        XCTAssertEqual(try store.token(forOwner: owner), "updated-token-value")
        try store.deleteToken(forOwner: owner)
        XCTAssertNil(try store.token(forOwner: owner))
    }

    func testGitRememberedUsernameIsScopedByRemoteWithoutStoringSecrets() throws {
        let suiteName = "ArborTests.RememberedUsernames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GitRememberedUsernameStore(defaults: defaults)

        store.setUsername("alice", for: "HTTPS://alice:token@example.com/org/repo.git")
        XCTAssertEqual(
            store.username(for: "https://example.com/org/repo.git"),
            "alice"
        )
        XCTAssertNil(store.username(for: "https://example.com/other.git"))

        let persisted = defaults.dictionary(forKey: "git.rememberedUsernames.v1")
        XCTAssertFalse(persisted?.values.contains(where: { ($0 as? String) == "token" }) == true)
    }

    func testAuthenticationFailureClearsOnlyMatchingGitSecret() throws {
        let keychain = KeychainStore(service: "com.arbor.tests.\(UUID().uuidString)")
        let suiteName = "ArborTests.FailedAuth.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let remembered = GitRememberedUsernameStore(defaults: defaults)
        let controller = CredentialAuthController(
            keychain: keychain,
            rememberedUsernameStore: remembered
        )
        try keychain.setGitCredential(secret: "bad-token", host: "example.com", username: "alice")
        try keychain.setGitCredential(secret: "keep-token", host: "example.com", username: "bob")
        defer {
            try? keychain.deleteGitCredential(host: "example.com", username: "alice")
            try? keychain.deleteGitCredential(host: "example.com", username: "bob")
            remembered.removeAll()
            defaults.removePersistentDomain(forName: suiteName)
        }

        controller.recordAuthenticationFailure(CredentialRequest(
            host: "example.com",
            username: "alice",
            remoteUrl: "https://example.com/org/repo.git",
            kind: .usernamePassword,
            attempt: 1,
            previousError: nil,
            prompt: "Password for 'https://alice@example.com/org/repo.git':",
            allowInteraction: true
        ))

        XCTAssertNil(try keychain.gitCredential(host: "example.com", username: "alice"))
        XCTAssertEqual(
            try keychain.gitCredential(host: "example.com", username: "bob"),
            "keep-token"
        )
    }
}
