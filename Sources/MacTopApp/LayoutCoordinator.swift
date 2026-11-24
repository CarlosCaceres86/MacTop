import Foundation
import MacTopCore

/// One owner for reads, saves and movement. Cancellation waits for the running move.
@MainActor
final class LayoutCoordinator {
    enum Event { case screensChanged, willSleep, didWake, locked, unlocked }
    enum RestorationPhase: Equatable { case recoveringDesktops, placingWindows, verifying }
    private enum Request { case inspect, save(external: Bool, expectedTopology: ProfileTopology?), restore(automatic: Bool, screenChange: Bool = false) }

    struct DesktopRecoverySession {
        var addOrdinaryDesktop: (String, DesktopSnapshot) async throws -> DesktopSnapshot = { _, _ in
            throw CoordinatorError.message("La creación de escritorios no está disponible.")
        }
        var placeOrdinaryDesktop: (OrdinaryDesktopReturnStep, DesktopSnapshot) async throws -> DesktopSnapshot = { _, _ in
            throw CoordinatorError.message("La devolución de escritorios no está disponible.")
        }
        var finish: () async throws -> Void = {}
    }

    struct Dependencies {
        var snapshot: () async throws -> DesktopSnapshot
        var displaySnapshot: () async throws -> DesktopSnapshot
        var move: (WindowMove, DesktopSnapshot) async throws -> Void
        var load: (ProfileTopology) throws -> LayoutProfile?
        var save: (LayoutProfile) throws -> Void
        var makeDesktopRecoverySession: () -> DesktopRecoverySession = { .init() }
        var loadDesktopRegistry: (LayoutProfile) throws -> ExternalDesktopRegistry? = { _ in nil }
        var saveDesktopRegistry: (ExternalDesktopRegistry, LayoutProfile) throws -> Void = { _, _ in }
        var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var physicalDisplaysMatch: (DesktopSnapshot) -> Bool = { _ in false }
    }

    private let dependencies: Dependencies
    private let desktopSessionID = UUID()
    private var task: Task<Void, Never>?
    private var requested: Request?
    private var sleeping = false
    private var locked = false
    private var stopped = false
    private var lastTopology: ProfileTopology?
    private var pendingRestore = false
    private var environmentChangedDuringRequest = false
    private var blockedDesktopProfile: (topology: ProfileTopology, capturedAt: Date)?
    private var reconnectDisplays: DesktopSnapshot?
    private(set) var automaticEnabled: Bool
    private(set) var isBusy = false
    private(set) var status = "Listo para guardar una distribución"
    private(set) var details: [String] = []
    private(set) var restorationPhase: RestorationPhase?
    private(set) var detectedTopology: ProfileTopology?
    private(set) var detectedDesktopCount: Int?
    private(set) var lastRestorationResult: (summary: String, details: [String], showsInMenu: Bool)?
    var onChange: (() -> Void)?

    init(dependencies: Dependencies, automaticEnabled: Bool = false) {
        self.dependencies = dependencies
        self.automaticEnabled = automaticEnabled
    }

    func start() { enqueue(automaticEnabled ? .restore(automatic: true) : .inspect) }
    func saveCurrent(external: Bool, expectedTopology: ProfileTopology? = nil) {
        enqueue(.save(external: external, expectedTopology: expectedTopology))
    }
    func restoreNow() { enqueue(.restore(automatic: false)) }

    func setAutomatic(_ enabled: Bool) {
        automaticEnabled = enabled
        if enabled {
            pendingRestore = true
            enqueue(.restore(automatic: true))
        } else {
            requested = nil
            cancelCurrent()
            publish("Restauración automática desactivada")
        }
    }

    func receive(_ event: Event) {
        guard !stopped else { return }
        if event == .screensChanged, let reconnectDisplays, restorationPhase != nil,
           dependencies.physicalDisplaysMatch(reconnectDisplays) { return }
        invalidateEnvironment()
        switch event {
        case .willSleep: sleeping = true
        case .locked: locked = true
        case .didWake: sleeping = false
        case .unlocked: locked = false
        case .screensChanged:
            pendingRestore = true
            requested = nil
            cancelCurrent()
        }
        if sleeping || locked {
            requested = nil
            cancelCurrent()
            publish("Esperando a que la sesión esté disponible")
        } else {
            enqueue(automaticEnabled ? .restore(automatic: true, screenChange: event == .screensChanged) : .inspect)
        }
    }

    func stop() {
        stopped = true
        requested = nil
        cancelCurrent()
        clearDetectedConfiguration()
    }

    // Also used by simulated tests; no live desktop is required.
    func waitUntilIdle() async {
        while let running = task { await running.value }
    }

    private func enqueue(_ request: Request) {
        guard !stopped, !sleeping, !locked else { return }
        requested = request
        cancelCurrent()
        runNext()
    }

    private func runNext() {
        guard task == nil, let request = requested, !stopped, !sleeping, !locked else { return }
        requested = nil
        isBusy = true
        environmentChangedDuringRequest = false
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.setRestorationPhase(nil)
                self.task = nil
                self.isBusy = false
                self.onChange?()
                self.runNext()
            }
            do {
                switch request {
                case .inspect:
                    let snapshot = try await self.stableSnapshot()
                    self.lastTopology = try snapshot.topology()
                    self.publish("Listo · guarda cada configuración por separado")
                case .save(let external, let expectedTopology):
                    let structure = try await self.stableSnapshot()
                    let snapshot = try await self.freshWindowSnapshot(matching: structure)
                    let topology = try snapshot.topology()
                    guard topology.isExternal == external else {
                        throw CoordinatorError.message(external
                            ? "Conecta el monitor externo antes de guardar ese perfil."
                            : "Desconecta el monitor externo antes de guardar el perfil MacBook.")
                    }
                    guard expectedTopology == nil || expectedTopology == topology else {
                        throw CoordinatorError.message("La configuración cambió; vuelve a abrir el menú antes de guardar.")
                    }
                    let profile = try LayoutProfile.capture(snapshot: snapshot)
                    try Task.checkCancellation()
                    try self.dependencies.save(profile)
                    if topology.isExternal {
                        try self.dependencies.saveDesktopRegistry(ExternalDesktopRegistry(profile: profile, snapshot: snapshot, sessionID: self.desktopSessionID), profile)
                        self.blockedDesktopProfile = nil
                    }
                    self.lastTopology = topology
                    let captured = RestorationPlanner.plan(profile: profile, snapshot: snapshot)
                    self.pendingRestore = !captured.isComplete
                    self.publish("Distribución guardada · \(external ? "MacBook + monitor" : "MacBook") · \(captured.pending.count) pendientes")
                case .restore(let automatic, let screenChange):
                    try await self.restore(automatic: automatic, screenChange: screenChange)
                }
            } catch is CancellationError {
                self.pendingRestore = true
                if self.requested == nil, !self.stopped, !self.sleeping, !self.locked {
                    self.publish(self.blockedDesktopProfile?.topology == self.lastTopology
                        ? "Operación interrumpida · es necesario reintentar manualmente con Restaurar ahora"
                        : "Operación interrumpida; puedes reintentar")
                }
            } catch {
                self.pendingRestore = true
                let summary = "Pendiente · \(error.localizedDescription)"
                if case .restore = request, !Task.isCancelled, !self.environmentChangedDuringRequest {
                    self.lastRestorationResult = (summary, [], true)
                }
                self.publish(summary)
                if let failure = error as? CoordinatorError, case .configurationChanged = failure,
                   self.automaticEnabled, !self.stopped, !self.sleeping, !self.locked {
                    self.requested = .restore(automatic: true, screenChange: true)
                }
            }
        }
        onChange?()
    }

    private func stableSnapshot() async throws -> DesktopSnapshot {
        var didStabilize = false
        defer { if !didStabilize { clearDetectedConfiguration() } }
        publish("Esperando pantallas y escritorios estables…")
        var previous: DesktopSnapshot?
        var repetitions = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var lastIssue = "Las pantallas o los escritorios no se estabilizan."
        for attempt in 0..<30 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            if attempt > 0 { try await dependencies.pause(.milliseconds(500)) }
            let snapshot: DesktopSnapshot
            do { snapshot = try await dependencies.displaySnapshot() }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastIssue = error.localizedDescription
                repetitions = 0
                previous = nil
                continue
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            guard snapshot.hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
            guard snapshot.isComplete, !snapshot.displays.isEmpty,
                  snapshot.displays.allSatisfy({ $0.frame.isValid && !$0.spaces.isEmpty && $0.spaces.allSatisfy({ $0.id > 0 && $0.kind != .unknown }) }) else {
                lastIssue = "El inventario de pantallas o escritorios sigue incompleto."
                repetitions = 0
                previous = nil
                continue
            }
            let unchanged = previous.map { snapshot.hasSameDisplayStructure(as: $0) } ?? false
            repetitions = unchanged ? repetitions + 1 : 1
            previous = snapshot
            if repetitions >= 3 {
                let topology = try snapshot.topology()
                let relevantDisplay = snapshot.displays.first { display in
                    switch topology {
                    case .portable: return display.isBuiltIn
                    case .external(let displayID): return display.id == displayID
                    }
                }
                detectedTopology = topology
                detectedDesktopCount = relevantDisplay?.spaces.filter { $0.kind == .ordinary }.count
                onChange?()
                try Task.checkCancellation()
                didStabilize = true
                return snapshot
            }
        }
        throw CoordinatorError.message("Las pantallas o los escritorios no se estabilizan. \(lastIssue) Reintenta cuando termine la conexión.")
    }

    private func freshWindowSnapshot(matching structure: DesktopSnapshot) async throws -> DesktopSnapshot {
        var didValidate = false
        defer { if !didValidate { clearDetectedConfiguration() } }
        try Task.checkCancellation()
        let snapshot = try await dependencies.snapshot()
        try Task.checkCancellation()
        guard snapshot.hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
        guard snapshot.isComplete else { throw MacTopCoreError.invalidSnapshot("El inventario está incompleto.") }
        guard snapshot.hasSameDisplayStructure(as: structure) else {
            invalidateEnvironment()
            throw CoordinatorError.configurationChanged("La configuración cambió; reintenta con las pantallas estables.")
        }
        didValidate = true
        return snapshot
    }

    private func restore(automatic: Bool, screenChange: Bool) async throws {
        let initial = try await stableSnapshot()
        let topology = try initial.topology()
        guard !automatic || pendingRestore || lastTopology != topology else {
            publish("Configuración sin cambios")
            return
        }
        let reconnecting = automatic && topology.isExternal && (screenChange || lastTopology == .portable)
        lastTopology = topology
        guard let profile = try dependencies.load(topology) else {
            pendingRestore = true
            let summary = "No hay una distribución guardada para esta configuración"
            lastRestorationResult = (summary, [], true)
            publish(summary)
            return
        }
        if blockedDesktopProfile?.topology == profile.topology, blockedDesktopProfile?.capturedAt == profile.capturedAt {
            if automatic {
                pendingRestore = true
                publish("Reintento manual necesario · Restaurar ahora", details: ["Una operación de escritorio anterior no quedó confirmada. Los avisos de pantalla, reposo o desbloqueo no autorizan otro gesto."])
                return
            }
            blockedDesktopProfile = nil
        }
        reconnectDisplays = reconnecting ? initial : nil
        defer { reconnectDisplays = nil }
        let recovery = try await recoverDesktops(profile: profile, snapshot: initial)
        if restorationPhase != nil { setRestorationPhase(.verifying) }
        let inventory = try await freshWindowSnapshot(matching: recovery.snapshot)
        let plan = RestorationPlanner.plan(profile: profile, snapshot: inventory)
        var failures: [String] = []
        var moved = 0
        var considered = Set<WindowIdentity>()
        func placeWindows(_ moves: [WindowMove]) async throws {
            for (index, move) in moves.enumerated() where considered.insert(move.identity).inserted {
                try Task.checkCancellation()
                let current = try await freshWindowSnapshot(matching: inventory)
                if RestorationPlanner.isRestored(move: move, snapshot: current) { continue }
                publish("Restaurando ventana \(index + 1) de \(moves.count)…")
                do {
                    try Task.checkCancellation()
                    setRestorationPhase(.placingWindows)
                    try Task.checkCancellation()
                    try await dependencies.move(move, current)
                    try Task.checkCancellation()
                    setRestorationPhase(.verifying)
                    let observed = try await freshWindowSnapshot(matching: inventory)
                    if RestorationPlanner.isRestored(move: move, snapshot: observed) {
                        moved += 1
                    } else {
                        failures.append("\(move.identity.diagnosticLabel): no se confirmó el destino.")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as CoordinatorError { throw error }
                catch { failures.append("\(move.identity.diagnosticLabel): \(error.localizedDescription)") }
            }
        }
        try await placeWindows(plan.moves)
        try Task.checkCancellation()
        if restorationPhase != nil { setRestorationPhase(.verifying) }
        var final = try await freshWindowSnapshot(matching: inventory)
        var remaining = RestorationPlanner.plan(profile: profile, snapshot: final)
        if reconnecting && !plan.pending.isEmpty {
            func missingWindows(in plan: RestorationPlan) -> [WindowIdentity] {
                plan.pending.filter { $0.reason == .applicationClosed || $0.reason == .windowUnavailable }.map(\.identity)
            }
            let destinations = profile.windows.filter { $0.destination != nil }.map(\.identity)
            var waiting = Set(missingWindows(in: plan)).intersection(destinations)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            var waits = 0
            while !waiting.isEmpty {
                let newMoves = remaining.moves.filter { waiting.contains($0.savedIdentity) }
                waiting.formIntersection(missingWindows(in: remaining))
                if !newMoves.isEmpty {
                    try await placeWindows(newMoves)
                } else {
                    let timeLeft = ContinuousClock.now.duration(to: deadline)
                    guard !waiting.isEmpty, timeLeft > .zero, waits < 2 else { break }
                    waits += 1
                    try await dependencies.pause(min(.milliseconds(500), timeLeft))
                }
                final = try await freshWindowSnapshot(matching: inventory)
                remaining = RestorationPlanner.plan(profile: profile, snapshot: final)
            }
        }
        var diagnostics = remaining.issues + remaining.pending.map { "\($0.identity.diagnosticLabel): \($0.reason.message)" }
        diagnostics += remaining.moves.map { "\($0.identity.diagnosticLabel): sigue fuera de su destino." }
        diagnostics += failures
        pendingRestore = !remaining.isComplete || !failures.isEmpty
        diagnostics += recovery.notes
        let extras = try (topology.isExternal ? OrdinaryDesktopReturn.extraDesktopCount(profile: profile, snapshot: final) : 0)
        if extras > 0 { diagnostics.append("Se conservan \(extras) escritorios adicionales en el monitor externo; MacTop no elimina escritorios.") }
        let creationSummary = recovery.created > 0 ? " · \(recovery.created) escritorios creados" : ""
        let returnSummary = recovery.returned > 0 ? " · \(recovery.returned) escritorios devueltos" : ""
        let extraSummary = extras > 0 ? " · \(extras) adicionales conservados" : ""
        let summary = (pendingRestore ? "Restauración parcial · \(moved) movimientos" : "Restaurado · \(moved) movimientos") + creationSummary + returnSummary + extraSummary
        lastRestorationResult = (summary, diagnostics, !pendingRestore || moved > 0)
        publish(summary, details: diagnostics)
    }

    private func recoverDesktops(profile: LayoutProfile, snapshot: DesktopSnapshot) async throws -> (snapshot: DesktopSnapshot, created: Int, returned: Int, notes: [String]) {
        guard case let .external(displayID) = profile.topology else { return (snapshot, 0, 0, []) }
        var current = snapshot
        var registry = try dependencies.loadDesktopRegistry(profile) ?? ExternalDesktopRegistry(profile: profile)
        var created = 0
        var returned = 0
        var notes: [String] = []
        var session: DesktopRecoverySession?
        var gestureStarted = false
        let slots = profile.displays.first { $0.role != .builtIn }?.spaces.count ?? 0
        do {
            // Each slot can require one creation and one placement, without retrying a failed gesture.
            for _ in 0...(slots * 2) {
                try Task.checkCancellation()
                let step = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registry: registry, sessionID: desktopSessionID)
                let observed: DesktopSnapshot
                switch step {
                case .ready:
                    notes += try OrdinaryDesktopReturn.identityIssues(profile: profile, snapshot: current, registry: registry, sessionID: desktopSessionID)
                    if let activeSession = session {
                        session = nil // A failed finish must not be attempted again by error cleanup.
                        gestureStarted = true
                        try await activeSession.finish()
                        gestureStarted = false
                    }
                    return (current, created, returned, notes)
                case .move(let move):
                    publish("Devolviendo escritorio \(move.targetIndex + 1) al monitor externo…")
                    let activeSession = session ?? dependencies.makeDesktopRecoverySession()
                    session = activeSession
                    try Task.checkCancellation()
                    setRestorationPhase(.recoveringDesktops)
                    try Task.checkCancellation()
                    gestureStarted = true
                    observed = try await activeSession.placeOrdinaryDesktop(move, current)
                    guard try OrdinaryDesktopReturn.isVerified(before: current, after: observed, step: move) else {
                        throw CoordinatorError.message("No se confirmó la devolución del escritorio; no se crearán duplicados ni se moverán sus ventanas por separado.")
                    }
                    returned += 1
                case .create(let slot, let reason):
                    publish("Creando escritorio \(slot + 1) en el monitor externo…")
                    let activeSession = session ?? dependencies.makeDesktopRecoverySession()
                    session = activeSession
                    try Task.checkCancellation()
                    setRestorationPhase(.recoveringDesktops)
                    try Task.checkCancellation()
                    gestureStarted = true
                    observed = try await activeSession.addOrdinaryDesktop(displayID, current)
                    guard try OrdinaryDesktopAddition.isVerified(before: current, after: observed, displayID: displayID) else {
                        throw CoordinatorError.message("La pulsación no creó un escritorio; no se volverá a pulsar automáticamente.")
                    }
                    try registry.recordCreated(before: current, after: observed, slot: slot, sessionID: desktopSessionID)
                    created += 1
                    try dependencies.saveDesktopRegistry(registry, profile)
                    if !notes.contains(reason) { notes.append(reason) }
                }
                try Task.checkCancellation()
                let stable = try await stableSnapshot()
                guard stable.hasSameDisplayStructure(as: observed) else {
                    invalidateEnvironment()
                    throw CoordinatorError.message("La configuración cambió tras recuperar escritorios; se han descartado los movimientos de ventanas.")
                }
                current = stable
                gestureStarted = false
            }
            throw CoordinatorError.message("No se pudo confirmar el orden de los escritorios; no se repetirán las operaciones automáticamente.")
        } catch {
            var failure = error
            if let session {
                do { try await session.finish() }
                catch {
                    gestureStarted = true
                    failure = CoordinatorError.message("\(failure.localizedDescription) No se confirmó el cierre de Mission Control: \(error.localizedDescription)")
                }
            }
            if gestureStarted { blockedDesktopProfile = (profile.topology, profile.capturedAt) }
            if failure is CancellationError { throw CancellationError() }
            let retry = gestureStarted ? " Es necesario reintentar manualmente con Restaurar ahora." : ""
            throw CoordinatorError.message("\(returned) escritorios devueltos · \(created) creados · \(failure.localizedDescription)\(retry)")
        }
    }

    private func cancelCurrent() {
        task?.cancel()
        setRestorationPhase(nil)
    }

    private func clearDetectedConfiguration() {
        detectedTopology = nil
        detectedDesktopCount = nil
        onChange?()
    }

    private func invalidateEnvironment() {
        environmentChangedDuringRequest = true
        clearDetectedConfiguration()
        setRestorationPhase(nil)
    }

    private func setRestorationPhase(_ phase: RestorationPhase?) {
        // Cancelled work may still finish cleanup, but must never show the veil again.
        guard phase == nil || (!Task.isCancelled && !stopped && !sleeping && !locked) else { return }
        guard restorationPhase != phase else { return }
        restorationPhase = phase
        onChange?()
    }

    private func publish(_ status: String, details: [String] = []) {
        self.status = status
        self.details = details
        onChange?()
    }
}

private enum CoordinatorError: LocalizedError {
    case message(String), configurationChanged(String)
    var errorDescription: String? {
        switch self { case .message(let text), .configurationChanged(let text): return text }
    }
}

extension ProfileTopology {
    var isExternal: Bool { if case .external = self { return true }; return false }
}

private extension WindowIdentity {
    var diagnosticLabel: String { "\(bundleIdentifier) · ventana \(windowID)" }
}
