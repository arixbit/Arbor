import Foundation
import SwiftUI

/// Git hooks 面板、脚本选择和编辑草稿。
@MainActor
final class HooksWorkspaceState: ObservableObject {
    @Published var showPanel = false
    @Published var hooks: [GitHookInfo] = []
    @Published var location: GitHooksLocation?
    @Published var selection: String?
    @Published var contents: GitHookContents?
    @Published var draft = ""
    @Published var busy = false
    @Published var feedback: String?
}
