import AppKit
import SwiftUI

/// AppKit launch windows have no SwiftUI scene, so FocusedValues cannot
/// supply their menu state. Resolve command state from the actual key window.
@MainActor
final class ArborWindowCommandContext: ObservableObject {
    static let shared = ArborWindowCommandContext()

    struct Entry: Equatable {
        let action: ArborVCSActionContext
        let operation: ArborVCSOperationContext?
    }

    @Published private(set) var active: Entry?
    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refresh), name: name, object: nil
            )
        }
    }

    func update(_ entry: Entry?, for window: NSWindow) {
        entries[ObjectIdentifier(window)] = entry
        refresh()
    }

    @objc private func refresh() {
        let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let window = keyWindow?.sheetParent ?? keyWindow
        let next = window.flatMap { entries[ObjectIdentifier($0)] }
        if active != next { active = next }
    }
}

struct ArborWindowCommandContextView: NSViewRepresentable {
    let action: ArborVCSActionContext
    let operation: ArborVCSOperationContext?

    func makeNSView(context: Context) -> CommandContextView {
        CommandContextView()
    }

    func updateNSView(_ view: CommandContextView, context: Context) {
        view.entry = ArborWindowCommandContext.Entry(action: action, operation: operation)
        view.publish()
    }

    static func dismantleNSView(_ view: CommandContextView, coordinator: ()) {
        view.detach()
    }

    final class CommandContextView: NSView {
        var entry: ArborWindowCommandContext.Entry?
        private weak var registeredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        func publish() {
            // Publishing during updateNSView would mutate observed state
            // while SwiftUI is rendering. Read the latest entry next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if registeredWindow !== window { detach() }
                guard let window else { return }
                registeredWindow = window
                ArborWindowCommandContext.shared.update(entry, for: window)
            }
        }

        func detach() {
            if let registeredWindow {
                ArborWindowCommandContext.shared.update(nil, for: registeredWindow)
            }
            registeredWindow = nil
        }
    }
}
