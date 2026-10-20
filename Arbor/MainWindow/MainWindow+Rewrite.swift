import SwiftUI
import AppKit


func cherryPickHighlightEnabledAfterSourceChange(
    sourceBranch: String,
    currentlyEnabled: Bool
) -> Bool {
    currentlyEnabled
        && !sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
