import Foundation
import SwiftUI

/// Shelf（IntelliJ 的 shelve/patch）工作区状态。
///
/// 分成三层：
/// - 列表：`shelves` 与 `deletedShelves`（Recently Deleted）；
/// - 选中 root 的加载状态：`rootPath` / `rootSnapshots` / 加载失败与代际；
/// - 预览、冲突与位置设置：预览用 name 而不是 index 作身份，避免列表刷新后
///   指向别的 shelf。
@MainActor
final class ShelfWorkspaceState: ObservableObject {
    // MARK: - 列表

    @Published var shelves: [ShelveInfo] = []
    @Published var deletedShelves: [ShelveInfo] = []
    @Published var name = ""
    @Published var showCreateDialog = false
    /// Monotonic request used by VCS > Git > Local Changes > Show Shelf/Stash.
    /// RebasedCommitWorkspace owns the tab state, so the request crosses the
    /// workspace boundary without making the parent duplicate that state.
    @Published var tabRequestID = 0
    @Published var isWorkspaceTabActive = false

    // MARK: - 按 root 加载

    @Published var rootPath: String?
    @Published var rootSnapshots: [String: ShelfRootSnapshot] = [:]
    @Published var rootRepository: Repository?
    @Published var rootLoading = false
    @Published var rootError: String?
    @Published var rootLoadGeneration = 0

    // MARK: - 预览

    @Published var previewName: String?
    @Published var previewIsDeleted = false
    @Published var previewText: String?
    @Published var previewRootPath: String?
    @Published var showPreview = false

    // MARK: - 冲突收尾

    @Published var conflictInProgress = false
    @Published var conflictIsPop = false
    @Published var conflictIsDirectPatch = false
    @Published var pendingConflictName: String?
    @Published var pendingConflictRepository: Repository?
    @Published var pendingConflictChangeList: String?
    @Published var pendingConflictPatch: String?
    @Published var pendingConflictNotificationID: String?

    // MARK: - Shelf 存放位置

    @Published var showLocationDialog = false
    @Published var locationValue = ""
    @Published var locationCurrent = ""
    @Published var locationMigrateExisting = true
}
