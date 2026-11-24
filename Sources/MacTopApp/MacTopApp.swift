import AppKit
import ApplicationServices
import MacTopCore
import MacTopSystem

@main
enum MacTopApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let icon = MacTopIcon.applicationImage { app.applicationIconImage = icon }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    let statusMenu = NSMenu()
    private let profileItem = NSMenuItem()
    private let messageItem = NSMenuItem()
    private lazy var permissionItem = command("Permitir Accesibilidad…", #selector(openAccessibilitySettings), symbol: "accessibility")
    private lazy var restoreItem = command("Restaurar ahora", #selector(restore), symbol: "arrow.counterclockwise")
    private lazy var saveItem = command("Guardar esta distribución…", #selector(saveDistribution(_:)), symbol: "square.and.arrow.down")
    private lazy var automaticItem = command("Restauración automática", #selector(toggleAutomatic))
    private let optionsMenu = NSMenu()
    private var menuIsOpen = false
    private var coordinator: LayoutCoordinator!
    private let overlay = RestorationOverlayController()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let automaticKey = "automaticRestorationEnabled"
    private var awaitingAccessibility = false
    private let hasAccessibility: () -> Bool
    private let requestAccessibility: @MainActor (MacWindowSystem) -> Void

    init(coordinator: LayoutCoordinator? = nil, hasAccessibility: @escaping () -> Bool = AXIsProcessTrusted,
         requestAccessibility: @escaping @MainActor (MacWindowSystem) -> Void = { $0.requestAccessibilityPermission() }) {
        self.coordinator = coordinator
        self.hasAccessibility = hasAccessibility
        self.requestAccessibility = requestAccessibility
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let system = MacWindowSystem()
        let store = ProfileStore()
        coordinator = coordinator ?? LayoutCoordinator(dependencies: .init(
            snapshot: { try await system.snapshot() },
            displaySnapshot: { try await system.displaySnapshot() },
            move: { try await system.move($0, expectedTopology: $1) },
            load: { try store.load($0) },
            save: { try store.save($0) },
            makeDesktopRecoverySession: {
                let session = system.makeDesktopRecoverySession()
                return .init(
                    addOrdinaryDesktop: { try await session.addOrdinaryDesktop(displayID: $0, expected: $1) },
                    placeOrdinaryDesktop: { try await session.placeOrdinaryDesktop($0, expected: $1) },
                    finish: { try await session.finish() }
                )
            },
            loadDesktopRegistry: { try store.loadExternalDesktopRegistry(profile: $0) },
            saveDesktopRegistry: { try store.saveExternalDesktopRegistry($0, profile: $1) },
            physicalDisplaysMatch: system.physicalDisplaysMatch
        ), automaticEnabled: UserDefaults.standard.bool(forKey: automaticKey))
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            self.overlay.update(phase: self.coordinator.restorationPhase, profileName: self.profileName)
            if self.menuIsOpen { self.updateMenuItems() }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MacTopIcon.statusImage()
        if item.button?.image == nil { item.button?.title = "MacTop" }
        item.button?.toolTip = "MacTop · Distribución de ventanas"
        configureMenu()
        item.menu = statusMenu

        awaitingAccessibility = !hasAccessibility()
        if awaitingAccessibility {
            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] event in
                let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
                MainActor.assumeIsolated { self?.checkForAccessibilityGrant() }
            }
            observers.append((center, observer))
            requestAccessibility(system)
        } else {
            startMonitoringDisplays()
        }
    }

    private func checkForAccessibilityGrant() {
        guard awaitingAccessibility, hasAccessibility() else { return }
        awaitingAccessibility = false
        startMonitoringDisplays()
    }

    private func startMonitoringDisplays() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .screensChanged)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, .willSleep)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, .didWake)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .locked)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), .unlocked)
        coordinator.start()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: LayoutCoordinator.Event) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.receive(event)
            }
        }
        observers.append((center, observer))
    }

    private func configureMenu() {
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        statusMenu.minimumWidth = 310
        profileItem.isEnabled = false
        messageItem.isEnabled = false
        optionsMenu.autoenablesItems = false
        optionsMenu.items = [
            command("Abrir carpeta de perfiles", #selector(openProfiles), symbol: "folder"),
            .separator(), command("Acerca de MacTop…", #selector(about), symbol: "info.circle")
        ]
        let options = NSMenuItem(title: "Más opciones", action: nil, keyEquivalent: "")
        options.submenu = optionsMenu
        statusMenu.items = [
            .sectionHeader(title: "Perfil detectado"), profileItem, messageItem, .separator(),
            permissionItem, restoreItem, saveItem, .separator(), automaticItem, .separator(),
            options, .separator(), command("Salir de MacTop", #selector(quit), key: "q")
        ]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        checkForAccessibilityGrant()
        updateMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func updateMenuItems() {
        let needsAccess = awaitingAccessibility || !hasAccessibility()
        let busy = coordinator.isBusy
        if profileItem.title != profileName {
            profileItem.title = profileName
            profileItem.attributedTitle = NSAttributedString(string: profileName, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor
            ])
        }
        profileItem.subtitle = screenInfo

        let last = coordinator.lastRestorationResult
        var message: String? = coordinator.status
        var note: String?
        if needsAccess {
            message = "Activa Accesibilidad para guardar y restaurar ventanas."
        } else if let last {
            if last.summary == coordinator.status && !last.showsInMenu {
                message = nil
            } else if !busy && last.showsInMenu {
                note = last.summary == coordinator.status ? last.details.first : "Última restauración · \(last.summary)"
            }
        }
        if messageItem.title != (message ?? "") || messageItem.subtitle != note {
            messageItem.title = message ?? ""
            messageItem.subtitle = note
            messageItem.view = message.map { Self.messageView(status: $0, note: note) }
        }
        messageItem.isHidden = message == nil
        permissionItem.isHidden = !needsAccess
        restoreItem.isEnabled = !needsAccess && !busy
        let topology = coordinator.detectedTopology
        saveItem.title = topology.map { "Guardar distribución para \(Self.name(for: $0))…" } ?? "Guardar esta distribución…"
        saveItem.representedObject = topology
        saveItem.isEnabled = !needsAccess && !busy && topology != nil
        automaticItem.isEnabled = !needsAccess || coordinator.automaticEnabled
        automaticItem.state = coordinator.automaticEnabled ? .on : .off
        for entry in optionsMenu.items where !entry.isSeparatorItem { entry.isEnabled = !busy }
    }

    private static func messageView(status: String, note: String?) -> NSView {
        let text = [status, note].compactMap { $0 }.joined(separator: "\n")
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = 278
        let height = ceil(label.fittingSize.height)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: height + 6))
        label.frame = NSRect(x: 14, y: 3, width: 278, height: height)
        row.addSubview(label)
        return row
    }

    private func command(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if let symbol {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        return entry
    }

    private var profileName: String {
        coordinator.detectedTopology.map(Self.name(for:)) ?? (coordinator.isBusy ? "Comprobando configuración…" : "Perfil sin identificar")
    }

    private var screenInfo: String? {
        guard let topology = coordinator.detectedTopology, let count = coordinator.detectedDesktopCount else { return nil }
        let desktops = "\(count) \(count == 1 ? "escritorio" : "escritorios")"
        return topology.isExternal ? "2 pantallas · \(desktops) en el monitor externo" : "1 pantalla · \(desktops)"
    }

    private static func name(for topology: ProfileTopology) -> String {
        topology.isExternal ? "MacBook + monitor" : "MacBook"
    }

    @objc private func saveDistribution(_ sender: NSMenuItem) {
        guard let topology = sender.representedObject as? ProfileTopology,
              !coordinator.isBusy, coordinator.detectedTopology == topology else { return }
        let confirmation = makeAlert(title: "Guardar para \(Self.name(for: topology))",
                                     message: "Se sustituirá el perfil de esta configuración por la distribución actual de las ventanas abiertas.")
        confirmation.addButton(withTitle: "Guardar distribución")
        confirmation.addButton(withTitle: "Cancelar").keyEquivalent = "\u{1b}"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        guard !coordinator.isBusy, coordinator.detectedTopology == topology else {
            alert(title: "La configuración ha cambiado", message: "Abre el menú de nuevo y comprueba el perfil detectado antes de guardar.")
            return
        }
        coordinator.saveCurrent(external: topology.isExternal, expectedTopology: topology)
    }
    @objc private func restore() {
        guard !coordinator.isBusy else { return }
        coordinator.restoreNow()
    }
    @objc private func toggleAutomatic() {
        let enabled = !coordinator.automaticEnabled
        UserDefaults.standard.set(enabled, forKey: automaticKey)
        coordinator.setAutomatic(enabled)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
           NSWorkspace.shared.open(url) { return }
        alert(title: "Permitir Accesibilidad", message: "En Ajustes del Sistema, abre Privacidad y seguridad → Accesibilidad y activa MacTop.")
    }

    @objc private func openProfiles() {
        guard !coordinator.isBusy else { return }
        let directory = ProfileStore.defaultDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { alert(title: "No se pudo abrir la carpeta", message: error.localizedDescription) }
    }

    @objc private func about() {
        guard !coordinator.isBusy else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "desarrollo"
        alert(title: "MacTop \(version) · Prueba local", message: "Recupera ventanas abiertas en sus escritorios guardados.\n\nGuarda por separado el perfil MacBook y el perfil MacBook + monitor. Prueba Restaurar ahora antes de activar el automatismo.\n\nSólo Guardar sustituye un perfil. Las apps y su contenido permanecen abiertos. Los perfiles se guardan localmente.\n\nMecanismo SpacePigeon 2.2.2 y componentes MIT; licencias en Contents/Resources/ThirdParty. Compatibilidad objetivo: macOS 26.6.2, pendiente de aceptación en el MacBook.")
    }

    private func makeAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        if let icon = MacTopIcon.applicationImage { alert.icon = icon }
        alert.messageText = title
        alert.informativeText = message
        return alert
    }

    private func alert(title: String, message: String) {
        guard !coordinator.isBusy else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = makeAlert(title: title, message: message)
        let accept = alert.addButton(withTitle: "Aceptar")
        let panel = alert.window
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === panel, event.keyCode == 53 else { return event }
            accept.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        alert.runModal()
    }

    @objc private func quit() {
        overlay.hide()
        coordinator.stop()
        Task {
            await coordinator.waitUntilIdle()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.hide()
        coordinator.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
