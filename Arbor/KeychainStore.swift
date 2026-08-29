import Foundation
import Security

/// Keychain-backed storage for hosting credentials.
///
/// The token is intentionally kept behind this type: it never crosses the
/// Rust FFI boundary and callers must not print it or persist it elsewhere.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()

    private let service: String

    init(service: String = "com.arbor.app") {
        self.service = service
    }

    func token(forOwner owner: String) throws -> String? {
        try value(forAccount: account(forOwner: owner))
    }

    func setToken(_ token: String, forOwner owner: String) throws {
        try setValue(token, forAccount: account(forOwner: owner))
    }

    func deleteToken(forOwner owner: String) throws {
        try deleteValue(forAccount: account(forOwner: owner))
    }

    func token(for repository: HostingRepository) throws -> String? {
        try value(forAccount: account(for: repository))
    }

    func setToken(_ token: String, for repository: HostingRepository) throws {
        try setValue(token, forAccount: account(for: repository))
    }

    func deleteToken(for repository: HostingRepository) throws {
        try deleteValue(forAccount: account(for: repository))
    }

    private func account(forOwner owner: String) -> String {
        "github:\(owner)"
    }

    private func account(for repository: HostingRepository) -> String {
        "\(repository.provider.rawValue):\(repository.host):\(repository.owner)"
    }

    // MARK: Git remote credential（AUTH-001）

    /// 按 (host, username) 读写 git remote 凭证；与 hosting token 分离建模。
    func gitCredential(host: String, username: String) throws -> String? {
        try value(forAccount: "git:\(host):\(username)")
    }

    func setGitCredential(secret: String, host: String, username: String) throws {
        try setValue(secret, forAccount: "git:\(host):\(username)")
    }

    func deleteGitCredential(host: String, username: String) throws {
        try deleteValue(forAccount: "git:\(host):\(username)")
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func value(forAccount account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError(status: status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError(status: errSecDecode)
        }
        return value
    }

    private func setValue(_ value: String, forAccount account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError(status: updateStatus)
        }
    }

    private func deleteValue(forAccount account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }
}

struct KeychainStoreError: Error, LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain operation failed (status \(status))"
    }
}
