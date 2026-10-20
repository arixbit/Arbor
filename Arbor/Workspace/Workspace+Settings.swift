import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Keep the embedded pinentry endpoint alive only for the Git operation that
/// may invoke GPG. Git's process runner injects this value into the child
/// environment, including hooks and GPG itself; all other repository refreshes
/// remain unaware of the session.
func withArborPinentrySession<T>(_ operation: () throws -> T) rethrows -> T {
    let token = try? ArborPinentryService.shared.startSession()
    if let token {
        setPinentryUserData(value: token)
    }
    defer {
        if token != nil {
            if ArborPinentryService.shared.stopSession() {
                setPinentryUserData(value: nil)
            }
        }
    }
    return try operation()
}
