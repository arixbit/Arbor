import Foundation
import SwiftUI

/// 文件选择、版本查看、预览与补丁交互状态。
@MainActor
final class FileWorkspaceState: ObservableObject {
    @Published var selection: String?
    @Published var fileSelection: String?
    @Published var version: FileContentVersion = .local
    /// Monotonic request used by the Project file-tree Annotate action. The
    /// file viewer owns the blame task; the parent only selects the path and
    /// asks the viewer to enter its existing Code/Blame mode.
    @Published var blameRequestID = 0
    @Published var treeDiffRequest: FileTreeDiffRequest?
    @Published var referenceComparisonRequest: FileReferenceComparisonRequest?
    @Published var currentRevisionRequest: CurrentRevisionRequest?
    /// Commit workspace preview stays inside the left Stage panel, matching
    /// rebased's split diff preview; it must not replace the right Log editor.
    @Published var previewPath: String?
    @Published var previewVisible = false
    @Published var previewMode: StagingPreviewMode = .unstaged
    @Published var previewComparisonMode: DiffMode?
    @Published var previewThreeVersions = false
    /// 逐行暂存入口：侧栏「逐行」点击后选中文件并让 diff 视图进入选择模式
    @Published var selectionModePath: String?
    @Published var revisionBrowserCommit: CommitInfo?
    @Published var revisionBrowserPath: String?
    @Published var showRevisionBrowser = false
    /// Invalidates read-only version viewers and staging diff previews after
    /// any visible status refresh, including worktree-only changes where the
    /// index did not change.
    @Published var refreshToken = 0
    @Published var pendingApplyPatch: RebasedApplyPatchRequest?
    @Published var patchExportRequest: PatchExportRequest?
    @Published var pendingIgnoreFileCreation: ContentView.IgnoreFileCreationRequest?
}
