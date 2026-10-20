import SwiftUI
import AppKit
import UniformTypeIdentifiers


enum GitStashViewSettings {
    static let splitPreviewKey = "arbor.git.stash.splitPreview.v1"
    static let defaultSplitPreview = true

    static func splitPreview(
        from defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: splitPreviewKey) == nil
            ? defaultSplitPreview
            : defaults.bool(forKey: splitPreviewKey)
    }

    static func saveSplitPreview(
        _ value: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(value, forKey: splitPreviewKey)
    }
}

/// Stash rows are addressed by their commit identity rather than their
/// volatile stack index. Dropping a stash shifts every older index, so both
/// actions and previews must resolve the index only at invocation time.
func stashIndex(forID id: String?, in stashes: [StashInfo]) -> Int? {
    guard let id else { return nil }
    return stashes.firstIndex { $0.id == id }
}
