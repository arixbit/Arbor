import Foundation
import SwiftUI

/// 克隆对话框、取消句柄与请求代际。
@MainActor
final class CloneWorkspaceState: ObservableObject {
    @Published var showDialog = false
    @Published var url = ""
    @Published var parentDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var directoryName = ""
    @Published var shallow = false
    @Published var depth = "1"
    @Published var inProgress = false
    @Published var cancelling = false
    @Published var cancelHandle: GitCancelHandle?
    @Published var requestGeneration = 0
}
