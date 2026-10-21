import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func showHostingAuthPromptIfNeeded(for results: [RootOperationResult]) {
    guard results.contains(where: { !$0.success && arborAuthenticationFailureMessage($0.message) }) else {
        return
    }
    hostingWorkspace.showHostingAuthPrompt = true
}

}
