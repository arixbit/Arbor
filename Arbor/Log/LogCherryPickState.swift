import Foundation
import SwiftUI

/// Cherry-pick 对比状态：为日志里的提交计算「是否已被挑过」。
///
/// 对比是跨 root 的后台任务，`generation` 与 `cancelHandle` 一起保证切换
/// 比较分支后旧结果不会写回。
@MainActor
final class LogCherryPickState: ObservableObject {
    @Published var comparisonTask: Task<Void, Never>?
    @Published var cancelHandle: GitCancelHandle?
    @Published var inProgress = false
    @Published var generation = 0
    @Published var completedRoots = 0
    @Published var totalRoots = 0

    @Published var cherryPickedCommitIDs: Set<String> = []
    @Published var comparisonReady = false
}
