import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

struct SubmoduleChangeRequest: Identifiable {
    let id: String
    let commit: CommitInfo
    let revision1: String
    let revision2: String
    let path: String
}

}
