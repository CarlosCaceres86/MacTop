import AppKit

enum MacTopIcon {
    static let applicationImage: NSImage? = Bundle.main.url(forResource: "MacTop", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    static func statusImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "desktopcomputer.and.macbook", accessibilityDescription: "MacTop")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }
}
