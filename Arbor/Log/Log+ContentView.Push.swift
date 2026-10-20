import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
// MARK: Git 日志工作区

@ViewBuilder
func pushTagAction(for tag: String) -> some View {
    let remoteNames = remotes.map(\.name)
    if remoteNames.count == 1 {
        Button("推送") { pushTag(tag, remote: remoteNames[0]) }
    } else if remoteNames.count > 1 {
        Menu("推送") {
            ForEach(remoteNames, id: \.self) { remote in
                Button(remote) {
                    pushTag(tag, remote: remote)
                }
            }
        }
    }
}

}
