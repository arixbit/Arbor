import SwiftUI
import UserNotifications
import Foundation
import AppKit


struct FeedbackMessageView: View {
    let message: FeedbackMessage
    let isCompact: Bool
    let onDetails: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.level.systemImage)
                .foregroundStyle(message.level.color)
            titleView
                .lineLimit(isCompact ? 1 : 2)
            if message.detail != nil || message.nextStep != nil {
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show operation details")
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if message.titleIsLocalized {
            Text(LocalizedStringKey(message.title))
        } else {
            Text(message.title)
        }
    }
}

struct FeedbackDetailView: View {
    let message: FeedbackMessage
    let onDismiss: () -> Void
    let onOpenSSHSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: message.level.systemImage)
                    .foregroundStyle(message.level.color)
                titleView
                    .font(.headline)
                Spacer()
            }
            if let detail = message.detail {
                Text(detail)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
            }
            if let nextStep = message.nextStep {
                Label {
                    Text(LocalizedStringKey(nextStep))
                } icon: {
                    Image(systemName: "arrow.right.circle")
                }
                .foregroundStyle(.secondary)
            }
            if !message.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(message.actions.enumerated()), id: \.element.id) { index, item in
                        if index == 0 {
                            Button {
                                onDismiss()
                                item.action()
                            } label: {
                                Text(LocalizedStringKey(item.title))
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                onDismiss()
                                item.action()
                            } label: {
                                Text(LocalizedStringKey(item.title))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if isChangedHostKey, let onOpenSSHSettings {
                Button("Open Git SSH Settings", action: onOpenSSHSettings)
                    .buttonStyle(.bordered)
            }
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, alignment: .leading)
    }

    @ViewBuilder
    private var titleView: some View {
        if message.titleIsLocalized {
            Text(LocalizedStringKey(message.title))
        } else {
            Text(message.title)
        }
    }

    private var isChangedHostKey: Bool {
        let detail = message.detail?.lowercased() ?? ""
        return detail.contains("ssh host key changed")
            || detail.contains("remote host identification has changed")
    }
}

struct FeedbackToastView: View {
    let message: FeedbackMessage
    let onDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FeedbackMessageView(message: message, isCompact: false, onDetails: onDetails)
            if !message.actions.isEmpty {
                ForEach(message.actions) { item in
                    Button {
                        item.action()
                        onDismiss()
                    } label: {
                        Text(LocalizedStringKey(item.title))
                    }
                    .buttonStyle(.bordered)
                }
            }
            if message.level == .error || message.level == .warning {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(message.level.color.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}
