import Foundation
import SwiftUI

/// 远程仓库列表与单 root、多 root 配置对话框。
@MainActor
final class RemoteWorkspaceState: ObservableObject {
    @Published var remotes: [RemoteInfo] = []
    @Published var name: String = ""
    @Published var url: String = ""
    @Published var showConfigDialog = false
    @Published var pushUrl: String = ""
    @Published var fetchRefspec: String = ""
    @Published var pushRefspec: String = ""
    @Published var multiRootRemoteConfigContext: MultiRootRemoteConfigContext?
    @Published var multiRootRemoteConfigAggregateContext: MultiRootRemoteConfigAggregateContext?
    @Published var multiRootRemoteName: String = ""
    @Published var multiRootRemoteURL: String = ""
    @Published var multiRootRemotePushURL: String = ""
    @Published var multiRootRemoteFetchRefspec: String = ""
    @Published var multiRootRemotePushRefspec: String = ""
}
