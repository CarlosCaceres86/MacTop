import AppKit

/// A visual cover only: it neither activates MacTop nor participates in restoration.
@MainActor
final class RestorationOverlayController {
    private(set) var panels: [RestorationOverlayPanel] = []
    private var phase: LayoutCoordinator.RestorationPhase?
    private var profileName = ""

    func update(phase: LayoutCoordinator.RestorationPhase?, profileName: String) {
        self.phase = phase
        self.profileName = profileName
        guard let phase else { hide(); return }
        if panels.isEmpty { rebuildPanels() }
        for panel in panels { panel.update(phase: phase, profileName: profileName) }
    }

    func hide() {
        phase = nil
        for panel in panels { panel.close() }
        panels.removeAll()
    }

    private func rebuildPanels() {
        guard let phase else { return }
        let screens = NSScreen.screens
        let primary = screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }) ?? NSScreen.main ?? screens.first
        panels = screens.map { screen in
            let panel = RestorationOverlayPanel(screen: screen, showsHUD: screen === primary)
            panel.update(phase: phase, profileName: profileName)
            panel.orderFrontRegardless()
            return panel
        }
    }
}

@MainActor
final class RestorationOverlayPanel: NSPanel {
    let showsHUD: Bool
    private let phaseLabel = NSTextField(labelWithString: "")
    private let profileLabel = NSTextField(labelWithString: "")

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, showsHUD: Bool) {
        self.showsHUD = showsHUD
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .floating
        collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = NSColor(srgbRed: 0.082, green: 0.165, blue: 0.247, alpha: 0.97)
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        title = String(localized: "Restoring layout · MacTop")
        guard showsHUD else { return }

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView = root
        let hud = NSView()
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor(srgbRed: 0.15, green: 0.235, blue: 0.295, alpha: 0.5).cgColor
        hud.layer?.cornerRadius = 14
        hud.layer?.borderWidth = 1
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        root.addSubview(hud)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.startAnimation(nil)
        spinner.setAccessibilityLabel(String(localized: "Restoration in progress"))
        phaseLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        phaseLabel.textColor = .white
        profileLabel.font = .systemFont(ofSize: 12)
        profileLabel.textColor = NSColor(srgbRed: 0.75, green: 0.82, blue: 0.85, alpha: 1)
        let labels = NSStackView(views: [phaseLabel, profileLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let row = NSStackView(views: [spinner, labels])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        hud.addSubview(row)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -22),
            row.topAnchor.constraint(equalTo: hud.topAnchor, constant: 21),
            row.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -21)
        ])
    }

    func update(phase: LayoutCoordinator.RestorationPhase, profileName: String) {
        switch phase {
        case .recoveringDesktops: phaseLabel.stringValue = String(localized: "Recovering desktops")
        case .placingWindows: phaseLabel.stringValue = String(localized: "Placing windows")
        case .verifying: phaseLabel.stringValue = String(localized: "Verifying layout")
        }
        profileLabel.stringValue = profileName
    }
}
