import AppKit

@MainActor
enum ArborAppIconController {
    private static var appearanceObservation: NSKeyValueObservation?

    static func install() {
        update()

        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { _, _ in
            Task { @MainActor in
                update()
            }
        }
    }

    private static func update() {
        guard let image = NSImage(named: NSImage.Name("ArborAppIcon")) else { return }
        NSApplication.shared.applicationIconImage = image
    }
}
