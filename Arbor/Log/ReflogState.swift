import Foundation
import SwiftUI

/// Reflog 视图状态：列表、分页、选中，以及 reflog 详情。
///
/// reflog 与主 Log 是两条独立的数据通路（独立的 root、仓库句柄与 generation），
/// 因此单独成对象比塞进 `LogListState` 更清楚：切 root 时两边互不影响。
@MainActor
final class ReflogState: ObservableObject {
    @Published var entries: [ReflogEntry] = []
    @Published var selection: String?
    @Published var selectedIDs: Set<String> = []

    @Published var rootPath: String?
    @Published var rootRepo: Repository?

    @Published var loadTask: Task<Void, Never>?
    @Published var loadMoreTask: Task<Void, Never>?
    @Published var generation = 0
    @Published var hasMore = false
    @Published var isLoadingMore = false

    @Published var detailCommit: CommitInfo?
    @Published var detailCommits: [CommitInfo] = []
    @Published var detailLoadTask: Task<Void, Never>?
}
