import Foundation
import SwiftUI

/// 版本比较输入、来源仓库、文件列表与加载任务。
@MainActor
final class ComparisonWorkspaceState: ObservableObject {
    @Published var loadTask: Task<Void, Never>?
    @Published var revision1: String = ""
    @Published var revision2: String = ""
    @Published var repositoryPath: String?
    @Published var withWorkingTree = false
    @Published var repository: Repository?
    @Published var treeChanges: [TreeChange] = []
    @Published var selection: String?
    @Published var selectedPaths: Set<String> = []
    @Published var error: String?
}
