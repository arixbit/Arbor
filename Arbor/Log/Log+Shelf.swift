import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// `Get Version` is a file-content action, not a single-commit patch action.
/// IntelliJ keeps every selected change for it, including selections spanning
/// commits and Git roots; an unselected contextual row falls back to itself.
func contextualLogChangeRestoreSelection(
    context: LogChangeRecord,
    selected: [LogChangeRecord]
) -> [LogChangeRecord] {
    guard selected.count > 1,
          selected.contains(where: { $0.id == context.id }) else {
        return [context]
    }
    return selected
}
