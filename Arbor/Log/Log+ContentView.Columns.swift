import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


var logColumnLayout: LogColumnLayout {
    LogColumnLayout(orderRaw: logColumnOrderRaw, widthsRaw: logColumnWidthsRaw)
}


func moveLogColumn(_ column: LogColumnID, by offset: Int) {
    logColumnOrderRaw = logColumnLayout.moving(column, by: offset).orderRaw
}


func canMoveLogColumn(_ column: LogColumnID, by offset: Int) -> Bool {
    guard let index = logColumnLayout.order.firstIndex(of: column) else { return false }
    return logColumnLayout.order.indices.contains(index + offset)
}


func resizeLogColumn(_ column: LogColumnID, by delta: CGFloat) {
    logColumnWidthsRaw = logColumnLayout
        .settingWidth(logColumnLayout.width(for: column) + delta, for: column)
        .widthsRaw
}


func setLogColumnWidth(_ column: LogColumnID, to width: CGFloat) {
    logColumnWidthsRaw = logColumnLayout.settingWidth(width, for: column).widthsRaw
}


/// Log 工具栏（视图切换、排序、列设置、刷新）。
var logGraphHeader: some View {
HStack(spacing: 10) {
    Button {
        logList.viewMode = .graph
    } label: {
        Label("Log", systemImage: "point.3.connected.trianglepath.dotted")
            .font(Design.Typography.interface(12, weight: .medium))
    }
    .buttonStyle(RebasedTabButtonStyle(isSelected: true))

    if externalLogWindow {
        externalLogRootsMenu
    }

    logGraphGearMenu

    Spacer(minLength: 0)
}
.padding(.horizontal, 8)
.frame(height: 36)
.background(Design.Colors.surface)
.overlay(alignment: .bottom) { Divider() }
.onChange(of: logList.viewMode) { _, mode in
    if mode == .graph {
        comparisonWorkspace.repository = nil
        comparisonWorkspace.repositoryPath = nil
        loadLog()
    } else if mode == .reflog {
        comparisonWorkspace.repository = nil
        comparisonWorkspace.repositoryPath = nil
        prepareReflogRoot()
    } else if mode == .command {
        comparisonWorkspace.repository = nil
        comparisonWorkspace.repositoryPath = nil
        runLogCommand()
    } else if mode == .tags {
        comparisonWorkspace.repository = nil
        comparisonWorkspace.repositoryPath = nil
        // Tags is its own Log sub-view. Do not leave the last History
        // commit rendered in the inspector while the left workspace
        // has already switched to tag management.
        logSelectionState.selection = nil
        logSelectionState.selectedIDs = []
    }
}
.onChange(of: logRuntime.sortModeRaw) { _, _ in
    guard logList.viewMode == .graph else { return }
    scheduleLogRefresh()
}
.onChange(of: logList.messageRegex) { _, _ in
    guard logList.viewMode == .graph else { return }
    scheduleLogRefresh()
}
.onChange(of: logList.messageMatchCase) { _, _ in
    guard logList.viewMode == .graph else { return }
    scheduleLogRefresh()
}
.onChange(of: logNoMerges) { _, _ in
    guard logList.viewMode == .graph else { return }
    scheduleLogRefresh()
}
.onChange(of: logCherryPickCompareBranch) { _, branch in
    logHighlightCherryPicked = cherryPickHighlightEnabledAfterSourceChange(
        sourceBranch: branch,
        currentlyEnabled: logHighlightCherryPicked
    )
    refreshCherryPickedHighlights()
}
.onChange(of: logHighlightCherryPicked) { _, _ in
    refreshCherryPickedHighlights()
}
}

}
