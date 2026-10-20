import Foundation
import SwiftUI

/// LFS 面板的能力、文件、跟踪输入与加载反馈。
@MainActor
final class LfsWorkspaceState: ObservableObject {
    @Published var showPanel = false
    @Published var capability: LfsCapability?
    @Published var patterns: [LfsTrackedPattern] = []
    @Published var files: [LfsFileEntry] = []
    @Published var hooks: LfsHookState?
    @Published var busy = false
    @Published var feedback: String?
    @Published var trackInput = ""
    @Published var remoteName = ""
    @Published var showAllRevisions = false
    @Published var selectedPaths: Set<String> = []
    @Published var trackedPaths: Set<String> = []
    @Published var pointerPaths: Set<String> = []
}
