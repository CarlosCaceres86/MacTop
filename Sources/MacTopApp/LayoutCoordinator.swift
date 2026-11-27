import Foundation
import MacTopCore

/// One owner for reads, saves and movement. Cancellation waits for the running move.
@MainActor
final class LayoutCoordinator {
    enum Event { case screensChanged, willSleep, didWake, locked, unlocked }
    enum RestorationPhase: Equatable { case recoveringDesktops, placingWindows, verifying }
    static let missingExternalProfile = String(localized: "This display setup has no saved profile yet.")
    private enum Request { case inspect, save(external: Bool, expectedTopology: ProfileTopology?), restore(automatic: Bool, screenChange: Bool = false) }

    struct DesktopRecoverySession {
        var addOrdinaryDesktop: (String, DesktopSnapshot) async throws -> DesktopSnapshot = { _, _ in
            throw CoordinatorError.message(String(localized: "Desktop creation is unavailable."))
        }
        var placeOrdinaryDesktop: (OrdinaryDesktopReturnStep, DesktopSnapshot) async throws -> DesktopSnapshot = { _, _ in
            throw CoordinatorError.message(String(localized: "Desktop recovery is unavailable."))
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
        var loadDesktopRegistry: (LayoutProfile, DisplayRole) throws -> ExternalDesktopRegistry? = { _, _ in nil }
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
    private var blockedDesktopProfiles: [ProfileTopology: Date] = [:]
    private var profileAvailability: (topology: ProfileTopology, exists: Bool)?
    private var reconnectDisplays: DesktopSnapshot?
    private(set) var automaticEnabled: Bool
    private(set) var isBusy = false
    private(set) var status = String(localized: "Ready to save a layout")
    private(set) var details: [String] = []
    private(set) var restorationPhase: RestorationPhase?
    private(set) var detectedTopology: ProfileTopology?
    private(set) var detectedDesktopCount: Int?
    private(set) var lastRestorationResult: (summary: String, details: [String], showsInMenu: Bool, topology: ProfileTopology?)?
    private var detectedDisplays: [DisplaySnapshot] = []
    var onChange: (() -> Void)?

    var detectedProfileName: String? {
        switch detectedTopology {
        case .portable: return "MacBook"
        case let .external(displayID):
            return displayName(displayID, in: detectedDisplays)
        case let .extended(builtIn, externalDisplayIDs):
            let monitors = externalDisplayIDs.map { displayName($0, in: detectedDisplays) }
            let names = zip(externalDisplayIDs, monitors).map { id, name in
                monitors.filter { $0 == name }.count > 1 ? "\(name) (\(id.suffix(6)))" : name
            }
            let combined = ((builtIn ? ["MacBook"] : []) + names).joined(separator: " + ")
            return builtIn ? combined : String(localized: "\(combined) · External only")
        case nil: return nil
        }
    }

    private func displayName(_ displayID: String, in displays: [DisplaySnapshot]) -> String {
        let display = displays.first { $0.id == displayID }
        if display?.isBuiltIn == true { return "MacBook" }
        if let name = display?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return String(localized: "Monitor \(String(displayID.suffix(6)))")
    }

    var lacksExternalProfile: Bool {
        guard let detectedTopology, detectedTopology.hasExternalDisplays, profileAvailability?.topology == detectedTopology else { return false }
        return profileAvailability?.exists == false
    }

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
            publish(String(localized: "Automatic restoration turned off"))
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
            publish(String(localized: "Waiting for the session to become available"))
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
                    let topology = try snapshot.topology()
                    self.lastTopology = topology
                    if topology.hasExternalDisplays { _ = try self.loadProfile(topology) }
                    self.publish(self.lacksExternalProfile ? Self.missingExternalProfile : String(localized: "Ready · Save a layout for each display setup"))
                case .save(let external, let expectedTopology):
                    let structure = try await self.stableSnapshot()
                    let snapshot = try await self.freshWindowSnapshot(matching: structure)
                    let topology = try snapshot.topology()
                    guard topology.hasExternalDisplays == external else {
                        throw CoordinatorError.message(external
                            ? String(localized: "Connect the external monitor before saving that profile.")
                            : String(localized: "Disconnect the external monitor before saving the MacBook profile."))
                    }
                    guard expectedTopology == nil || expectedTopology == topology else {
                        throw CoordinatorError.message(String(localized: "The display setup changed. Reopen the menu before saving."))
                    }
                    let profile = try LayoutProfile.capture(snapshot: snapshot)
                    let registries = try topology.displayRoles.map { role in
                        try ExternalDesktopRegistry(profile: profile, role: role, snapshot: snapshot, sessionID: self.desktopSessionID)
                    }
                    try Task.checkCancellation()
                    try self.dependencies.save(profile)
                    self.profileAvailability = (topology, true)
                    for registry in registries {
                        try self.dependencies.saveDesktopRegistry(registry, profile)
                    }
                    self.blockedDesktopProfiles[topology] = nil
                    self.lastTopology = topology
                    let captured = RestorationPlanner.plan(profile: profile, snapshot: snapshot)
                    self.pendingRestore = !captured.isComplete
                    let name = self.detectedProfileName ?? "MacBook"
                    self.publish(String(localized: "Layout saved · \(name) · \(captured.pending.count) pending"))
                case .restore(let automatic, let screenChange):
                    try await self.restore(automatic: automatic, screenChange: screenChange)
                }
            } catch is CancellationError {
                self.pendingRestore = true
                if self.requested == nil, !self.stopped, !self.sleeping, !self.locked {
                    self.publish(self.lastTopology.flatMap { self.blockedDesktopProfiles[$0] } != nil
                        ? String(localized: "Restoration interrupted · Use Restore Now to retry manually")
                        : String(localized: "Restoration interrupted. You can try again."))
                }
            } catch {
                self.pendingRestore = true
                let summary = String(localized: "Pending · \(error.localizedDescription)")
                if case .restore = request, !Task.isCancelled, !self.environmentChangedDuringRequest {
                    self.lastRestorationResult = (summary, [], true, self.detectedTopology)
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
        publish(String(localized: "Waiting for displays and desktops to stabilize…"))
        var previous: DesktopSnapshot?
        var repetitions = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var lastIssue = String(localized: "The displays or desktops did not stabilize.")
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
                lastIssue = String(localized: "The display or desktop inventory is still incomplete.")
                repetitions = 0
                previous = nil
                continue
            }
            let unchanged = previous.map { snapshot.hasSameDisplayStructure(as: $0) } ?? false
            repetitions = unchanged ? repetitions + 1 : 1
            previous = snapshot
            if repetitions >= 3 {
                let topology = try snapshot.topology()
                let relevantDisplays: [DisplaySnapshot]
                if case let .external(displayID) = topology {
                    relevantDisplays = snapshot.displays.filter { $0.id == displayID }
                } else {
                    relevantDisplays = snapshot.displays
                }
                detectedTopology = topology
                detectedDesktopCount = relevantDisplays.reduce(0) { $0 + $1.spaces.filter { $0.kind == .ordinary }.count }
                detectedDisplays = snapshot.displays
                onChange?()
                try Task.checkCancellation()
                didStabilize = true
                return snapshot
            }
        }
        throw CoordinatorError.message(String(localized: "The displays or desktops did not stabilize. \(lastIssue) Try again once the display has finished connecting."))
    }

    private func freshWindowSnapshot(matching structure: DesktopSnapshot) async throws -> DesktopSnapshot {
        var didValidate = false
        defer { if !didValidate { clearDetectedConfiguration() } }
        try Task.checkCancellation()
        let snapshot = try await dependencies.snapshot()
        try Task.checkCancellation()
        guard snapshot.hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
        guard snapshot.isComplete else { throw MacTopCoreError.invalidSnapshot(String(localized: "The inventory is incomplete.")) }
        guard snapshot.hasSameDisplayStructure(as: structure) else {
            invalidateEnvironment()
            throw CoordinatorError.configurationChanged(String(localized: "The display setup changed. Try again once the displays are stable."))
        }
        didValidate = true
        return snapshot
    }

    private func loadProfile(_ topology: ProfileTopology) throws -> LayoutProfile? {
        profileAvailability = nil
        let profile = try dependencies.load(topology)
        profileAvailability = (topology, profile != nil)
        return profile
    }

    private func restore(automatic: Bool, screenChange: Bool) async throws {
        let initial = try await stableSnapshot()
        let topology = try initial.topology()
        guard !automatic || pendingRestore || lastTopology != topology else {
            publish(String(localized: "Display setup unchanged"))
            return
        }
        let reconnecting = automatic && (screenChange || lastTopology.map { $0 != topology } == true)
        lastTopology = topology
        guard let profile = try loadProfile(topology) else {
            pendingRestore = true
            let summary = topology.hasExternalDisplays ? Self.missingExternalProfile : String(localized: "No layout is saved for this display setup")
            lastRestorationResult = (summary, [], !topology.hasExternalDisplays, topology)
            publish(summary)
            return
        }
        if blockedDesktopProfiles[topology] == profile.capturedAt {
            if automatic {
                pendingRestore = true
                publish(String(localized: "Manual retry required · Restore Now"), details: [
                    String(localized: "MacTop could not verify the previous desktop operation. Check the layout before retrying.")
                ])
                return
            }
            blockedDesktopProfiles[topology] = nil
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
                publish(String(localized: "Restoring window \(index + 1) of \(moves.count)…"))
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
                        failures.append(String(localized: "\(move.identity.diagnosticLabel): The destination could not be verified."))
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
        diagnostics += remaining.moves.map { String(localized: "\($0.identity.diagnosticLabel): The window is still outside its destination.") }
        diagnostics += failures
        pendingRestore = !remaining.isComplete || !failures.isEmpty
        diagnostics += recovery.notes
        let extras = try OrdinaryDesktopReturn.extraDesktopCount(profile: profile, snapshot: final)
        if extras > 0 {
            diagnostics.append(extras == 1
                ? String(localized: "Kept \(extras) extra desktop.")
                : String(localized: "Kept \(extras) extra desktops."))
        }
        let outcome = pendingRestore ? String(localized: "Partial restoration") : String(localized: "Restored")
        let moves = moved == 1 ? String(localized: "\(moved) move") : String(localized: "\(moved) moves")
        var summaryParts = [outcome, moves]
        if recovery.created > 0 {
            summaryParts.append(recovery.created == 1
                ? String(localized: "\(recovery.created) desktop created") : String(localized: "\(recovery.created) desktops created"))
        }
        if recovery.returned > 0 {
            summaryParts.append(recovery.returned == 1
                ? String(localized: "\(recovery.returned) desktop returned") : String(localized: "\(recovery.returned) desktops returned"))
        }
        if extras > 0 {
            summaryParts.append(String(localized: "\(extras) extra kept", comment: "Number of extra desktops kept."))
        }
        let summary = summaryParts.joined(separator: " · ")
        lastRestorationResult = (summary, diagnostics, !pendingRestore || moved > 0, topology)
        publish(summary, details: diagnostics)
    }

    private func recoverDesktops(profile: LayoutProfile, snapshot: DesktopSnapshot) async throws -> (snapshot: DesktopSnapshot, created: Int, returned: Int, notes: [String]) {
        var current = snapshot
        var registries = try profile.topology.displayRoles.map { role in
            try dependencies.loadDesktopRegistry(profile, role) ?? ExternalDesktopRegistry(profile: profile, role: role)
        }
        var created = 0
        var returned = 0
        var notes: [String] = []
        var session: DesktopRecoverySession?
        var gestureStarted = false
        let slots = profile.displays.reduce(0) { $0 + $1.spaces.count }
        do {
            // Allow a return, fallback creation and reorder per slot, plus a retained auxiliary per display.
            for _ in 0...(slots * 3 + profile.displays.count) {
                try Task.checkCancellation()
                let step = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: desktopSessionID)
                let observed: DesktopSnapshot
                switch step {
                case .ready:
                    notes += try OrdinaryDesktopReturn.identityIssues(profile: profile, snapshot: current, registries: registries, sessionID: desktopSessionID)
                    if let activeSession = session {
                        session = nil // A failed finish must not be attempted again by error cleanup.
                        gestureStarted = true
                        try await activeSession.finish()
                        gestureStarted = false
                    }
                    return (current, created, returned, notes)
                case .move(let move):
                    let name = displayName(move.targetDisplayID, in: current.displays)
                    publish(String(localized: "Returning desktop \(move.targetIndex + 1) to \(name)…"))
                    let activeSession = session ?? dependencies.makeDesktopRecoverySession()
                    session = activeSession
                    try Task.checkCancellation()
                    setRestorationPhase(.recoveringDesktops)
                    try Task.checkCancellation()
                    gestureStarted = true
                    observed = try await activeSession.placeOrdinaryDesktop(move, current)
                    guard try OrdinaryDesktopReturn.isVerified(before: current, after: observed, step: move) else {
                        throw CoordinatorError.message(String(localized: "Could not verify the desktop return. MacTop stopped before creating duplicates or moving its windows separately."))
                    }
                    returned += 1
                case .create(let displayID, let slot, let reason):
                    guard let index = registries.firstIndex(where: { current.display(for: $0.role)?.id == displayID }) else {
                        throw CoordinatorError.message(String(localized: "The destination display could not be verified."))
                    }
                    let name = displayName(displayID, in: current.displays)
                    publish(String(localized: "Creating a desktop on \(name)…"))
                    let activeSession = session ?? dependencies.makeDesktopRecoverySession()
                    session = activeSession
                    try Task.checkCancellation()
                    setRestorationPhase(.recoveringDesktops)
                    try Task.checkCancellation()
                    gestureStarted = true
                    observed = try await activeSession.addOrdinaryDesktop(displayID, current)
                    guard try OrdinaryDesktopAddition.isVerified(before: current, after: observed, displayID: displayID) else {
                        throw CoordinatorError.message(String(localized: "The click did not create a desktop. MacTop will wait for a manual retry."))
                    }
                    if let slot {
                        try registries[index].recordCreated(before: current, after: observed, slot: slot, sessionID: desktopSessionID)
                        try dependencies.saveDesktopRegistry(registries[index], profile)
                    }
                    created += 1
                    if !notes.contains(reason) { notes.append(reason) }
                }
                try Task.checkCancellation()
                let stable = try await stableSnapshot()
                guard stable.hasSameDisplayStructure(as: observed) else {
                    invalidateEnvironment()
                    throw CoordinatorError.message(String(localized: "The display setup changed after desktop recovery. MacTop canceled the remaining window moves."))
                }
                current = stable
                gestureStarted = false
            }
            throw CoordinatorError.message(String(localized: "Could not verify the desktop order. Use Restore Now to retry."))
        } catch {
            var failure = error
            if let session {
                do { try await session.finish() }
                catch {
                    gestureStarted = true
                    failure = CoordinatorError.message(String(localized: "\(failure.localizedDescription) Could not verify that Mission Control closed: \(error.localizedDescription)"))
                }
            }
            if gestureStarted { blockedDesktopProfiles[profile.topology] = profile.capturedAt }
            if failure is CancellationError { throw CancellationError() }
            let returnedSummary = returned == 1
                ? String(localized: "\(returned) desktop returned") : String(localized: "\(returned) desktops returned")
            let summary = String(localized: "\(returnedSummary) · \(created) created · \(failure.localizedDescription)")
            let retry = gestureStarted ? " " + String(localized: "Use Restore Now to retry manually.") : ""
            throw CoordinatorError.message(summary + retry)
        }
    }

    private func cancelCurrent() {
        task?.cancel()
        setRestorationPhase(nil)
    }

    private func clearDetectedConfiguration() {
        detectedTopology = nil
        detectedDesktopCount = nil
        detectedDisplays = []
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

private extension WindowIdentity {
    var diagnosticLabel: String { String(localized: "\(bundleIdentifier) · window \(windowID)") }
}
