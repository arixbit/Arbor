import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
// MARK: Git 日志工作区

@ViewBuilder
func pushTagAction(for tag: String) -> some View {
    let remoteNames = remoteWorkspace.remotes.map(\.name)
    if remoteNames.count == 1 {
        Button("Push") { pushTag(tag, remote: remoteNames[0]) }
    } else if remoteNames.count > 1 {
        Menu("Push") {
            ForEach(remoteNames, id: \.self) { remote in
                Button(remote) {
                    pushTag(tag, remote: remote)
                }
            }
        }
    }
}

}
