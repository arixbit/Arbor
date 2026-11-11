import SwiftUI
import AppKit
import UniformTypeIdentifiers


enum GitStashViewSettings {
    static let splitPreviewKey = "arbor.git.stash.splitPreview.v1"
    static let defaultSplitPreview = true
    static let groupByDirectoryKey = "groupByDirectory"
    static let defaultGroupByDirectory = true

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

    static func groupByDirectory(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = projectKey(groupByDirectoryKey, projectPath: projectPath) else {
            return defaultGroupByDirectory
        }
        return defaults.object(forKey: key) == nil
            ? defaultGroupByDirectory
            : defaults.bool(forKey: key)
    }

    static func saveGroupByDirectory(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = projectKey(groupByDirectoryKey, projectPath: projectPath) else { return }
        defaults.set(value, forKey: key)
    }

    private static func projectKey(_ suffix: String, projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return "arbor.git.stash.project.v1:\(data.base64EncodedString()):\(suffix)"
    }
}

/// Stash rows are addressed by their commit identity rather than their
/// volatile stack index. Dropping a stash shifts every older index, so both
/// actions and previews must resolve the index only at invocation time.
func visibleStashChangeRows(
    paths: [String],
    groupByDirectory: Bool,
    collapsedFolders: Set<String>
) -> [ShelfTreeRow] {
    let rows = shelfTreeRows(paths: paths, groupByDirectory: groupByDirectory)
    guard groupByDirectory else { return rows }
    return rows.filter { row in
        !rows.contains { folder in
            folder.isFolder
                && row.path.hasPrefix(folder.path + "/")
                && collapsedFolders.contains(folder.path)
        }
    }
}

func stashIndex(forID id: String?, in stashes: [StashInfo]) -> Int? {
    guard let id else { return nil }
    return stashes.firstIndex { $0.id == id }
}
