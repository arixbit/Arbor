import SwiftUI
import AppKit


struct MultiRootCheckoutUpdateRetryContext {
    let reference: String
    let selectedRootPaths: [String]
    let detach: Bool
    let rebase: Bool
    let mode: MultiRootCheckoutMode
}
