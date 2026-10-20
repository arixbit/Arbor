import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Mirrors IntelliJ's post-fetch suggestion. It is deliberately attached to
/// a successful manual fetch, capped at three prompts, and never replaces the
/// completed operation with a separate warning entry.
func shouldSuggestAutoFetch(
    autoFetchEnabled: Bool,
    suggestionDisabled: Bool,
    shownCount: Int
) -> Bool {
    !autoFetchEnabled && !suggestionDisabled && shownCount < 3
}
