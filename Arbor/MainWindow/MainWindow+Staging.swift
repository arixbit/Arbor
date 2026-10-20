import SwiftUI
import AppKit


/// side-by-side 渲染：每个 hunk 一个头部 + 配对行。
enum DiffHunkAction: String, CaseIterable, Hashable {
    case stage
    case unstage
    case rollback

    var title: String {
        switch self {
        case .stage: "Stage Hunk"
        case .unstage: "Unstage Hunk"
        case .rollback: "Rollback Hunk"
        }
    }

    var systemImage: String {
        switch self {
        case .stage: "plus"
        case .unstage: "minus"
        case .rollback: "arrow.uturn.backward"
        }
    }
}

struct HunkHeaderView: View {
    let hunk: DiffHunk
    var actions: [DiffHunkAction] = []
    var actionsDisabled = false
    var onAction: (DiffHunkAction) -> Void = { _ in }

    var body: some View {
        HStack {
            Text("@@ -\(hunk.oldStart),\(hunk.oldLines.count) +\(hunk.newStart),\(hunk.newLines.count) @@")
                .font(Design.Typography.codeSmall)
                .foregroundStyle(Design.Colors.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Design.Colors.selection, in: Capsule())
            Spacer()
            ForEach(actions, id: \.self) { action in
                if action == .rollback {
                    Button(role: .destructive) {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(actionsDisabled)
                } else {
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(actionsDisabled)
                }
            }
        }
        .padding(.horizontal, Design.Spacing.sm)
        .padding(.vertical, 3)
        .background(Design.Colors.surface)
    }
}
