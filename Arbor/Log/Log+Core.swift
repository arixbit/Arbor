import SwiftUI
import AppKit
import UniformTypeIdentifiers

import SwiftUI
import AppKit

/// Returns the adjacent row used by a Changes Browser diff preview.
/// Keeping this independent of SwiftUI makes wrap/selection boundaries
/// explicit and testable.
func adjacentChangeIndex(count: Int, current: Int, offset: Int) -> Int? {
    guard count > 0, (0..<count).contains(current) else { return nil }
    let next = current + offset
    return (0..<count).contains(next) ? next : nil
}

/// Returns the first/last Changes Browser row when keyboard navigation starts
/// without an active row, or the adjacent row when one is already selected.
/// IntelliJ's changes tree keeps arrow navigation inside the visible file
/// rows instead of requiring a mouse click before the first diff can open.
func keyboardChangeIndex(count: Int, current: Int?, offset: Int) -> Int? {
    guard count > 0, offset != 0 else { return nil }
    guard let current else { return offset > 0 ? 0 : count - 1 }
    return adjacentChangeIndex(count: count, current: current, offset: offset)
}
