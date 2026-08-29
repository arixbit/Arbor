import SwiftUI
import AppKit

struct WorkspacePanelHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let trailing: AnyView?

    init(
        title: LocalizedStringKey,
        systemImage: String,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        trailing: AnyView? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 12)
                    Label(title, systemImage: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .help(isExpanded ? "Collapse panel" : "Expand panel")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "Collapse panel" : "Expand panel")
    }
}

struct WorkspacePanelResizeHandle: View {
    @Binding var topHeight: Double
    let minimumTopHeight: Double
    let maximumTopHeight: Double
    @State private var dragOrigin: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 7)
            .overlay {
                Capsule()
                .fill(Color.primary.opacity(0.18))
                    .frame(width: 42, height: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = dragOrigin ?? topHeight
                        if dragOrigin == nil { dragOrigin = origin }
                        topHeight = min(
                            max(origin + Double(value.translation.height), minimumTopHeight),
                            maximumTopHeight
                        )
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .help("Drag to resize Commit and Project panels")
            .accessibilityLabel("Resize Commit and Project panels")
    }
}

/// IntelliJ/rebased 主工作区的左右分隔线：左侧工具窗与右侧内容区共享一个
/// 可持久化比例，分隔线本身只有很窄的视觉宽度，但保留足够大的命中区域。
struct WorkspaceColumnResizeHandle: View {
    @Binding var leftWidth: Double
    let minimumLeftWidth: Double
    let maximumLeftWidth: Double
    var onEnded: (Double) -> Void = { _ in }
    @State private var dragOrigin: Double?
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = dragOrigin ?? leftWidth
                        if dragOrigin == nil { dragOrigin = origin }
                        leftWidth = min(
                            max(origin + Double(value.translation.width), minimumLeftWidth),
                            maximumLeftWidth
                        )
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        onEnded(leftWidth)
                    }
            )
            .help("Drag to resize left and right workspaces")
            .accessibilityLabel("Resize left and right workspaces")
    }
}

/// The native divider owns the live drag. Updating a SwiftUI/AppStorage value
/// for every mouse event makes the entire ContentView participate in the drag
/// and is especially expensive while the log graph is mounted. NSSplitView
/// keeps the two hosted workspaces laid out in AppKit until mouse-up, then
/// writes the final width back to SwiftUI once.
final class WorkspaceNativeSplitView: NSSplitView {
    var onResizeEnded: (() -> Void)?

    override var dividerThickness: CGFloat { 12 }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.48).setFill()
        NSBezierPath(roundedRect: NSRect(
            x: rect.midX - 3.5,
            y: rect.midY - 29,
            width: 7,
            height: 58
        ), xRadius: 3.5, yRadius: 3.5).fill()

        // Rebased exposes a small bidirectional grip at the midpoint. Keep
        // it inside the native divider so it remains visual feedback for the
        // same live NSSplitView drag, instead of adding a second SwiftUI
        // gesture layer that would reintroduce layout hitching.
        let grip = NSBezierPath()
        grip.move(to: NSPoint(x: rect.midX - 4, y: rect.midY))
        grip.line(to: NSPoint(x: rect.midX + 4, y: rect.midY))
        grip.move(to: NSPoint(x: rect.midX - 4, y: rect.midY))
        grip.line(to: NSPoint(x: rect.midX - 1, y: rect.midY + 2.5))
        grip.move(to: NSPoint(x: rect.midX - 4, y: rect.midY))
        grip.line(to: NSPoint(x: rect.midX - 1, y: rect.midY - 2.5))
        grip.move(to: NSPoint(x: rect.midX + 4, y: rect.midY))
        grip.line(to: NSPoint(x: rect.midX + 1, y: rect.midY + 2.5))
        grip.move(to: NSPoint(x: rect.midX + 4, y: rect.midY))
        grip.line(to: NSPoint(x: rect.midX + 1, y: rect.midY - 2.5))
        NSColor.secondaryLabelColor.withAlphaComponent(0.9).setStroke()
        grip.lineWidth = 1.2
        grip.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onResizeEnded?()
    }
}

struct NativeWorkspaceColumns<SidebarContent: View, MainContent: View>: NSViewRepresentable {
    @Binding var sidebarWidth: Double
    let sidebarContent: SidebarContent
    let mainContent: MainContent
    let minimumSidebarWidth: CGFloat
    let minimumMainWidth: CGFloat

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var parent: NativeWorkspaceColumns
        weak var splitView: WorkspaceNativeSplitView?
        weak var sidebarHost: NSHostingView<SidebarContent>?
        weak var mainHost: NSHostingView<MainContent>?
        var isApplyingExternalPosition = false
        var rootUpdateScheduled = false

        init(parent: NativeWorkspaceColumns) {
            self.parent = parent
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
            // When a window is narrower than both requested minimums, keep
            // the main/editor column's minimum first. The old `max(minLeft,
            // available - minRight)` formula silently violated the right
            // minimum and collapsed the Log details inspector to a strip.
            let maximumSidebarWidth = max(0, availableWidth - parent.minimumMainWidth)
            let minimumSidebarWidth = min(parent.minimumSidebarWidth, maximumSidebarWidth)
            return min(
                max(proposedPosition, minimumSidebarWidth),
                maximumSidebarWidth
            )
        }

        func commitCurrentPosition() {
            guard let splitView,
                  splitView.subviews.count >= 2 else { return }
            let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
            let maximumSidebarWidth = max(0, availableWidth - parent.minimumMainWidth)
            let minimumSidebarWidth = min(parent.minimumSidebarWidth, maximumSidebarWidth)
            let width = min(
                max(splitView.subviews[0].frame.width, minimumSidebarWidth),
                maximumSidebarWidth
            )
            guard abs(parent.sidebarWidth - Double(width)) > 0.5 else { return }
            parent.sidebarWidth = Double(width)
        }

        func applyExternalPositionIfNeeded() {
            guard let splitView,
                  splitView.subviews.count >= 2 else { return }
            let availableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
            let maximumSidebarWidth = max(0, availableWidth - parent.minimumMainWidth)
            let minimumSidebarWidth = min(parent.minimumSidebarWidth, maximumSidebarWidth)
            let target = min(
                max(CGFloat(parent.sidebarWidth), minimumSidebarWidth),
                maximumSidebarWidth
            )
            let current = splitView.subviews[0].frame.width
            guard abs(current - target) > 0.5,
                  !isApplyingExternalPosition else { return }
            isApplyingExternalPosition = true
            splitView.setPosition(target, ofDividerAt: 0)
            isApplyingExternalPosition = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WorkspaceNativeSplitView {
        let splitView = WorkspaceNativeSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: sidebarContent)
        let mainHost = NSHostingView(rootView: mainContent)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        mainHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mainHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebarHost.setContentCompressionResistancePriority(.required, for: .horizontal)
        mainHost.setContentCompressionResistancePriority(.required, for: .horizontal)

        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(mainHost)

        context.coordinator.splitView = splitView
        context.coordinator.sidebarHost = sidebarHost
        context.coordinator.mainHost = mainHost
        context.coordinator.parent = self
        splitView.onResizeEnded = { [weak coordinator = context.coordinator] in
            coordinator?.commitCurrentPosition()
        }
        return splitView
    }

    func updateNSView(_ splitView: WorkspaceNativeSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Assigning an NSHostingView root during updateNSView makes the
        // hosted SwiftUI tree publish while its parent is still resolving,
        // which produces AttributeGraph cycles and visible drag hitching.
        // Coalesce changes and apply them on the next run-loop turn instead.
        guard !coordinator.rootUpdateScheduled else { return }
        coordinator.rootUpdateScheduled = true
        DispatchQueue.main.async { [weak coordinator] in
            guard let coordinator else { return }
            coordinator.rootUpdateScheduled = false
            coordinator.sidebarHost?.rootView = coordinator.parent.sidebarContent
            coordinator.mainHost?.rootView = coordinator.parent.mainContent
            coordinator.applyExternalPositionIfNeeded()
        }
    }
}

/// Reusable IntelliJ-style horizontal splitter for nested workspaces such as
/// Git Log's graph/details pair. It shares the same native divider and grip as
/// the outer Commit/Stash ↔ editor split, so every draggable boundary has one
/// visible affordance and one live drag path.
struct WorkspaceHorizontalSplit<LeftContent: View, RightContent: View>: View {
    @Binding var persistedLeftWidth: Double
    let leftContent: LeftContent
    let rightContent: RightContent
    let minimumLeftWidth: CGFloat
    let minimumRightWidth: CGFloat

    init(
        persistedLeftWidth: Binding<Double>,
        minimumLeftWidth: CGFloat,
        minimumRightWidth: CGFloat,
        @ViewBuilder leftContent: () -> LeftContent,
        @ViewBuilder rightContent: () -> RightContent
    ) {
        _persistedLeftWidth = persistedLeftWidth
        self.minimumLeftWidth = minimumLeftWidth
        self.minimumRightWidth = minimumRightWidth
        self.leftContent = leftContent()
        self.rightContent = rightContent()
    }

    var body: some View {
        NativeWorkspaceColumns(
            sidebarWidth: $persistedLeftWidth,
            sidebarContent: leftContent,
            mainContent: rightContent,
            minimumSidebarWidth: minimumLeftWidth,
            minimumMainWidth: minimumRightWidth
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceSplitLayout<SidebarContent: View, MainContent: View>: View {
    @Binding var persistedSidebarWidth: Double
    let selectedToolWindow: ToolWindowMode
    let sidebarVisible: Bool
    let onSelectToolWindow: (ToolWindowMode) -> Void
    let onOpenProject: () -> Void
    let sidebarContent: SidebarContent
    let mainContent: MainContent
    init(
        persistedSidebarWidth: Binding<Double>,
        selectedToolWindow: ToolWindowMode,
        sidebarVisible: Bool = true,
        onSelectToolWindow: @escaping (ToolWindowMode) -> Void,
        onOpenProject: @escaping () -> Void,
        @ViewBuilder sidebarContent: () -> SidebarContent,
        @ViewBuilder mainContent: () -> MainContent
    ) {
        _persistedSidebarWidth = persistedSidebarWidth
        self.selectedToolWindow = selectedToolWindow
        self.sidebarVisible = sidebarVisible
        self.onSelectToolWindow = onSelectToolWindow
        self.onOpenProject = onOpenProject
        self.sidebarContent = sidebarContent()
        self.mainContent = mainContent()
    }

    var body: some View {
        HStack(spacing: 0) {
            RebasedActivityRail(
                selectedMode: selectedToolWindow,
                onSelect: onSelectToolWindow,
                onOpenProject: onOpenProject
            )
            .frame(width: 52)

            if sidebarVisible {
                NativeWorkspaceColumns(
                    sidebarWidth: $persistedSidebarWidth,
                    sidebarContent: sidebarContent,
                    mainContent: mainContent,
                    minimumSidebarWidth: 280,
                    minimumMainWidth: 420
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
