import Foundation
import SwiftUI

/// 双栏分支比较的列表、过滤、选中与分页状态。
/// 两侧各自持有任务和请求代际；generation 标识当前比较上下文。
@MainActor
final class BranchComparisonState: ObservableObject {
    @Published var firstEntries: [CommitInfo] = []
    @Published var secondEntries: [CommitInfo] = []
    @Published var firstFilter = BranchComparisonFilter()
    @Published var secondFilter = BranchComparisonFilter()
    @Published var selectionID: String?
    @Published var selectionSide: BranchComparisonSide = .first
    @Published var firstLoading = false
    @Published var secondLoading = false
    @Published var firstHasMore = false
    @Published var secondHasMore = false
    @Published var generation = 0
    @Published var firstRequestGeneration = 0
    @Published var secondRequestGeneration = 0
    @Published var firstLoadTask: Task<Void, Never>?
    @Published var secondLoadTask: Task<Void, Never>?
    @Published var firstError: String?
    @Published var secondError: String?
    @Published var error: String?
    @Published var isLoading = false
}
