import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Keeps multi-file compare actions deterministic and follows the order in
/// the Git tree diff rather than the unspecified order of a Set.
func orderedCompareSelection(changes: [TreeChange], selectedPaths: Set<String>) -> [TreeChange] {
    changes.filter { selectedPaths.contains($0.path) }
}
