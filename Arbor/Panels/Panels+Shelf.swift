import SwiftUI
import AppKit
import UniformTypeIdentifiers


enum ShelfViewSettings {
    static let keyPrefix = "arbor.commit.shelves.project.v2:"
    static let showRecycledKey = "showRecycled"
    static let removeAppliedKey = "removeAppliedFilesFromShelf"
    static let shelvesExpandedKey = "shelvesExpanded"
    static let groupByDirectoryKey = "groupByDirectory"
    static let deletedShelvesExpandedKey = "deletedShelvesExpanded"

    static func baseKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return "\(keyPrefix)\(data.base64EncodedString())"
    }

    static func key(for projectPath: String?) -> String? {
        guard let baseKey = baseKey(for: projectPath) else { return nil }
        return "\(baseKey):\(showRecycledKey)"
    }

    static func showRecycled(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(for: projectPath),
              defaults.object(forKey: key) != nil else { return false }
        return defaults.bool(forKey: key)
    }

    static func saveShowRecycled(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        defaults.set(value, forKey: key)
    }

    static func removeAppliedFilesFromShelf(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let baseKey = baseKey(for: projectPath) else { return false }
        let key = "\(baseKey):\(removeAppliedKey)"
        return defaults.object(forKey: key) != nil && defaults.bool(forKey: key)
    }

    static func saveRemoveAppliedFilesFromShelf(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let baseKey = baseKey(for: projectPath) else { return }
        defaults.set(value, forKey: "\(baseKey):\(removeAppliedKey)")
    }

    static func shelvesExpanded(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(for: shelvesExpandedKey, projectPath: projectPath, defaultValue: true, defaults: defaults)
    }

    static func saveShelvesExpanded(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        save(value, for: shelvesExpandedKey, projectPath: projectPath, defaults: defaults)
    }

    static func groupByDirectory(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(for: groupByDirectoryKey, projectPath: projectPath, defaultValue: true, defaults: defaults)
    }

    static func saveGroupByDirectory(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        save(value, for: groupByDirectoryKey, projectPath: projectPath, defaults: defaults)
    }

    static func deletedShelvesExpanded(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(for: deletedShelvesExpandedKey, projectPath: projectPath, defaultValue: true, defaults: defaults)
    }

    static func saveDeletedShelvesExpanded(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        save(value, for: deletedShelvesExpandedKey, projectPath: projectPath, defaults: defaults)
    }

    static func value(
        for suffix: String,
        projectPath: String?,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard let baseKey = baseKey(for: projectPath) else { return defaultValue }
        let key = "\(baseKey):\(suffix)"
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func save(
        _ value: Bool,
        for suffix: String,
        projectPath: String?,
        defaults: UserDefaults
    ) {
        guard let baseKey = baseKey(for: projectPath) else { return }
        defaults.set(value, forKey: "\(baseKey):\(suffix)")
    }
}

func shelfTimestampLabel(_ timestamp: Int64) -> String {
    guard timestamp > 0 else { return "" }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
        .formatted(date: .abbreviated, time: .shortened)
}

struct ShelfTreeRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    let isFolder: Bool
}

func shelfTreeRows(paths: [String], groupByDirectory: Bool) -> [ShelfTreeRow] {
    let sortedPaths = paths.sorted {
        intellijFilePathCompare($0, $1, flattened: !groupByDirectory) == .orderedAscending
    }
    guard groupByDirectory else {
        return sortedPaths.map {
            ShelfTreeRow(id: "file:\($0)", name: $0, path: $0, depth: 0, isFolder: false)
        }
    }

    var rows: [ShelfTreeRow] = []
    var folders = Set<String>()
    for path in sortedPaths {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { continue }
        if components.count > 1 {
            var prefix = ""
            for (index, component) in components.dropLast().enumerated() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if folders.insert(prefix).inserted {
                    rows.append(ShelfTreeRow(
                        id: "folder:\(prefix)",
                        name: component,
                        path: prefix,
                        depth: index,
                        isFolder: true
                    ))
                }
            }
        }
        rows.append(ShelfTreeRow(
            id: "file:\(path)",
            name: components.last ?? path,
            path: path,
            depth: max(0, components.count - 1),
            isFolder: false
        ))
    }
    return rows
}

func shelfMemberSelectionID(shelfID: String, path: String) -> String {
    "\(shelfID)\u{1F}\(path)"
}

enum ShelfDropPayload: Equatable {
    case shelf(String)
    case member(shelf: String, path: String)
}

struct ShelfPathDeleteGroup: Equatable, Sendable {
    let shelfName: String
    let paths: [String]
}

struct ShelfDeletePlan: Equatable, Sendable {
    let activeShelfNames: [String]
    let activePathGroups: [ShelfPathDeleteGroup]
    let deletedShelfNames: [String]
    let deletedPathGroups: [ShelfPathDeleteGroup]

    var isEmpty: Bool {
        activeShelfNames.isEmpty
            && activePathGroups.isEmpty
            && deletedShelfNames.isEmpty
            && deletedPathGroups.isEmpty
    }
}

enum ShelfDeleteOperationKind: String, Equatable, Sendable {
    case activeShelf
    case activePaths
    case deletedShelf
    case deletedPaths
}

struct ShelfDeleteOperation: Equatable, Sendable {
    let kind: ShelfDeleteOperationKind
    let shelfName: String
    let paths: [String]

    var key: String {
        let scope: String
        switch kind {
        case .activeShelf: scope = "active-shelf"
        case .activePaths: scope = "active-paths"
        case .deletedShelf: scope = "deleted-shelf"
        case .deletedPaths: scope = "deleted-paths"
        }
        return "\(scope)\u{1f}\(shelfName)\u{1f}\(paths.joined(separator: "\u{1f}"))"
    }

    var displayName: String {
        switch kind {
        case .activeShelf, .activePaths:
            shelfName
        case .deletedShelf, .deletedPaths:
            shelfName + " (Recently Deleted)"
        }
    }
}

/// Expands the DeleteProvider scope into the same stable ordering used by the
/// unified Shelf deletion runner: active lists, active members, deleted lists,
/// then deleted members. The plan builder already gives whole-list selection
/// precedence over child selection, so no operation here can overlap another.
func shelfDeleteOperations(_ plan: ShelfDeletePlan) -> [ShelfDeleteOperation] {
    plan.activeShelfNames.map {
        ShelfDeleteOperation(kind: .activeShelf, shelfName: $0, paths: [])
    }
    + plan.activePathGroups.map {
        ShelfDeleteOperation(kind: .activePaths, shelfName: $0.shelfName, paths: $0.paths)
    }
    + plan.deletedShelfNames.map {
        ShelfDeleteOperation(kind: .deletedShelf, shelfName: $0, paths: [])
    }
    + plan.deletedPathGroups.map {
        ShelfDeleteOperation(kind: .deletedPaths, shelfName: $0.shelfName, paths: $0.paths)
    }
}

/// Builds the same delete scope that IntelliJ's Shelf DeleteProvider receives
/// from the tree: a selected list wins over its selected child changes, while
/// child changes from different lists remain independent operations.
func shelfDeletePlan(
    visibleShelves: [ShelveInfo],
    deletedShelves: [ShelveInfo],
    selectedShelfIDs: Set<String>,
    selectedShelfMemberIDs: Set<String>,
    selectedDeletedShelfIDs: Set<String>,
    selectedDeletedShelfMemberIDs: Set<String>
) -> ShelfDeletePlan {
    func pathGroups(
        shelves: [ShelveInfo],
        selectedShelfIDs: Set<String>,
        selectedMemberIDs: Set<String>
    ) -> (names: [String], groups: [ShelfPathDeleteGroup]) {
        var names: [String] = []
        var groups: [ShelfPathDeleteGroup] = []
        for shelf in shelves where selectedShelfIDs.contains(shelf.id) {
            names.append(shelf.name)
        }
        for shelf in shelves where !selectedShelfIDs.contains(shelf.id) {
            let paths = shelf.paths.filter {
                selectedMemberIDs.contains(
                    shelfMemberSelectionID(shelfID: shelf.id, path: $0)
                )
            }
            if !paths.isEmpty {
                groups.append(ShelfPathDeleteGroup(shelfName: shelf.name, paths: paths))
            }
        }
        return (names, groups)
    }

    let active = pathGroups(
        shelves: visibleShelves,
        selectedShelfIDs: selectedShelfIDs,
        selectedMemberIDs: selectedShelfMemberIDs
    )
    let deleted = pathGroups(
        shelves: deletedShelves,
        selectedShelfIDs: selectedDeletedShelfIDs,
        selectedMemberIDs: selectedDeletedShelfMemberIDs
    )
    return ShelfDeletePlan(
        activeShelfNames: active.names,
        activePathGroups: active.groups,
        deletedShelfNames: deleted.names,
        deletedPathGroups: deleted.groups
    )
}

/// Decode the two drag payloads used by the Shelf tree. Keeping this parser
/// separate from the drop views prevents a member payload from accidentally
/// falling through to the whole-Shelf Unshelve action.
func parseShelfDropPayload(_ payload: String) -> ShelfDropPayload? {
    let shelfPrefix = "arbor-shelf:"
    let memberPrefix = "arbor-shelf-member:"
    if payload.hasPrefix(shelfPrefix) {
        let name = String(payload.dropFirst(shelfPrefix.count))
        return name.isEmpty ? nil : .shelf(name)
    }
    guard payload.hasPrefix(memberPrefix) else { return nil }
    let body = payload.dropFirst(memberPrefix.count)
    guard let separator = body.firstIndex(of: "\u{1F}") else { return nil }
    let shelf = String(body[..<separator])
    let path = String(body[body.index(after: separator)...])
    guard !shelf.isEmpty, !path.isEmpty else { return nil }
    return .member(shelf: shelf, path: path)
}
