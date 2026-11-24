import Foundation

public struct ExternalDesktopIdentity: Codable, Equatable, Sendable {
    public let stableUUID: UUID?
    public var createdUUID: UUID?
    public var sessionSpaceID: UInt64?
    public var sessionSpaceUUID: UUID?
    public var sessionID: UUID?

    public init(stableUUID: UUID? = nil, createdUUID: UUID? = nil, sessionSpaceID: UInt64? = nil, sessionSpaceUUID: UUID? = nil, sessionID: UUID? = nil) {
        self.stableUUID = stableUUID; self.createdUUID = createdUUID
        self.sessionSpaceID = sessionSpaceID; self.sessionSpaceUUID = sessionSpaceUUID; self.sessionID = sessionID
    }
}

/// Separate recovery evidence; saving it never rewrites the user's layout profile.
public struct ExternalDesktopRegistry: Codable, Equatable, Sendable {
    public let displayID: String
    public let capturedAt: Date
    public private(set) var slots: [ExternalDesktopIdentity]

    public init(profile: LayoutProfile) throws {
        try profile.validate()
        guard case let .external(id) = profile.topology,
              let display = profile.displays.first(where: { $0.role == .external(id: id) }) else {
            throw MacTopCoreError.invalidProfile("El registro requiere un perfil externo.")
        }
        displayID = id; capturedAt = profile.capturedAt
        slots = display.spaces.indices.map { ExternalDesktopIdentity(stableUUID: display.spaceUUIDs?[$0]) }
    }

    /// Only explicit "Save this layout" may seed live IDs by the observed ordinal.
    public init(profile: LayoutProfile, snapshot: DesktopSnapshot, sessionID: UUID) throws {
        try self.init(profile: profile)
        let captured = try LayoutProfile.capture(snapshot: snapshot)
        guard captured.topology == profile.topology, captured.displays == profile.displays,
              let display = snapshot.displays.first(where: { $0.id == displayID && !$0.isBuiltIn }) else {
            throw MacTopCoreError.invalidSnapshot("La captura cambió antes de registrar sus escritorios.")
        }
        for index in slots.indices {
            slots[index].sessionSpaceID = display.spaces[index].id
            slots[index].sessionSpaceUUID = display.spaces[index].stableUUID
            slots[index].sessionID = sessionID
        }
    }

    public func matches(profile: LayoutProfile) -> Bool {
        guard case let .external(id) = profile.topology,
              let saved = profile.displays.first(where: { $0.role == .external(id: id) }) else { return false }
        return displayID == id && capturedAt == profile.capturedAt && slots.count == saved.spaces.count
    }

    func validate(profile: LayoutProfile) throws {
        try profile.validate()
        guard matches(profile: profile),
              let saved = profile.displays.first(where: { $0.role == .external(id: displayID) }) else {
            throw MacTopCoreError.invalidProfile("El registro de escritorios no corresponde a esta captura y monitor.")
        }
        var identities = Set<UUID>()
        for (index, slot) in slots.enumerated() {
            guard slot.stableUUID == saved.spaceUUIDs?[index],
                  (slot.sessionSpaceID == nil) == (slot.sessionID == nil),
                  slot.sessionSpaceID == nil || slot.sessionSpaceID! > 0 else {
                throw MacTopCoreError.invalidProfile("El registro contiene una identidad de escritorio inconsistente.")
            }
            for uuid in Set([slot.stableUUID, slot.createdUUID].compactMap { $0 }) {
                guard identities.insert(uuid).inserted else {
                    throw MacTopCoreError.invalidProfile("El registro contiene identidades de escritorio duplicadas.")
                }
            }
        }
    }

    /// Records only the newly appended Space after an exact, verified addition.
    public mutating func recordCreated(before: DesktopSnapshot, after: DesktopSnapshot, slot: Int, sessionID: UUID) throws {
        guard slots.indices.contains(slot),
              try OrdinaryDesktopAddition.isVerified(before: before, after: after, displayID: displayID),
              let space = after.displays.first(where: { $0.id == displayID })?.spaces.last else {
            throw MacTopCoreError.invalidSnapshot("No se pudo registrar el escritorio creado.")
        }
        let previous = slots[slot]
        let originalUUIDs = [previous.stableUUID, previous.createdUUID].compactMap { $0 }
        let alreadyKnown = before.displays.flatMap(\.spaces).contains { existing in
            if let uuid = existing.stableUUID, originalUUIDs.contains(uuid) { return true }
            return previous.sessionID == sessionID && previous.sessionSpaceID == existing.id &&
                previous.sessionSpaceUUID == existing.stableUUID
        }
        guard !alreadyKnown else {
            throw MacTopCoreError.invalidSnapshot("El destino ya tiene un escritorio identificado; se conserva su identidad.")
        }
        let uuids = after.displays.flatMap(\.spaces).compactMap(\.stableUUID)
        if let uuid = space.stableUUID, uuids.filter({ $0 == uuid }).count != 1 {
            throw MacTopCoreError.invalidSnapshot("El UUID del escritorio creado está duplicado.")
        }
        // Keep the original UUID so it wins if a temporarily missing Space reappears.
        slots[slot].createdUUID = space.stableUUID
        slots[slot].sessionSpaceID = space.id
        slots[slot].sessionSpaceUUID = space.stableUUID
        slots[slot].sessionID = sessionID
    }
}

public struct OrdinaryDesktopReturnStep: Equatable, Sendable {
    public let spaceID: UInt64
    public let stableUUID: UUID?
    public let sourceDisplayID: String
    public let targetDisplayID: String
    public let targetIndex: Int
    public let slot: Int

    public init(spaceID: UInt64, stableUUID: UUID? = nil, sourceDisplayID: String, targetDisplayID: String, targetIndex: Int, slot: Int) {
        self.spaceID = spaceID; self.stableUUID = stableUUID
        self.sourceDisplayID = sourceDisplayID; self.targetDisplayID = targetDisplayID
        self.targetIndex = targetIndex; self.slot = slot
    }
}

public enum ExternalDesktopRecoveryStep: Equatable, Sendable {
    case move(OrdinaryDesktopReturnStep)
    case create(slot: Int, reason: String)
    case ready
}

public enum OrdinaryDesktopReturn {
    public static func nextStep(profile: LayoutProfile, snapshot: DesktopSnapshot, registry: ExternalDesktopRegistry, sessionID: UUID) throws -> ExternalDesktopRecoveryStep {
        let (saved, external) = try context(profile: profile, snapshot: snapshot, registry: registry)
        guard saved.spaces.allSatisfy({ $0 == .ordinary }), external.spaces.allSatisfy({ $0.kind == .ordinary }) else { return .ready }
        let resolved = try saved.spaces.indices.map { try resolve(slot: $0, saved: saved, snapshot: snapshot, registry: registry, sessionID: sessionID) }
        let knownIDs = resolved.compactMap { $0?.space.id }
        guard Set(knownIDs).count == knownIDs.count else { throw changed("Dos destinos apuntan al mismo escritorio.") }
        for slot in saved.spaces.indices {
            guard let original = resolved[slot] else { continue }
            if original.display.id == external.id, external.spaces.firstIndex(where: { $0.id == original.space.id }) == slot { continue }
            guard original.space.kind == .ordinary,
                  original.display.isBuiltIn || original.display.id == external.id,
                  !original.display.isBuiltIn || original.display.spaces.filter({ $0.kind == .ordinary }).count > 1 else {
                throw changed("No se puede devolver el escritorio conservando un escritorio ordinario en la pantalla integrada.")
            }
            // Return known Spaces first; missing capacity is filled after their identities are safe.
            if original.display.id == external.id && slot >= external.spaces.count { continue }
            guard !original.display.isBuiltIn || external.spaces.count < OrdinaryDesktopAddition.maximumOrdinaryDesktops else {
                throw changed("El monitor externo ya tiene 16 escritorios; no se puede devolver otro sin eliminar uno.")
            }
            return .move(.init(spaceID: original.space.id, stableUUID: original.space.stableUUID, sourceDisplayID: original.display.id,
                               targetDisplayID: external.id, targetIndex: min(slot, external.spaces.count), slot: slot))
        }
        if try OrdinaryDesktopAddition.missingCount(profile: profile, snapshot: snapshot) > 0 {
            let unknownSlots = saved.spaces.indices.filter { resolved[$0] == nil }
            let available = external.spaces.filter { !knownIDs.contains($0.id) }.count
            guard unknownSlots.indices.contains(available) else { throw changed() }
            return .create(slot: unknownSlots[available], reason: "No se ha identificado un escritorio original disponible para este destino; se creará el escritorio que falta.")
        }
        return .ready
    }

    public static func identityIssues(profile: LayoutProfile, snapshot: DesktopSnapshot, registry: ExternalDesktopRegistry, sessionID: UUID) throws -> [String] {
        let (saved, _) = try context(profile: profile, snapshot: snapshot, registry: registry)
        let observed = Set(snapshot.displays.flatMap(\.spaces).compactMap(\.stableUUID))
        return saved.spaces.indices.compactMap { slot in
            guard let uuid = saved.spaceUUIDs?[slot] ?? registry.slots[slot].stableUUID ?? registry.slots[slot].createdUUID, !observed.contains(uuid) else { return nil }
            return "No aparece el UUID original del escritorio \(slot + 1); se usará el destino ordinario disponible sin borrar su identidad guardada."
        }
    }

    public static func extraDesktopCount(profile: LayoutProfile, snapshot: DesktopSnapshot) throws -> Int {
        let (saved, external) = try context(profile: profile, snapshot: snapshot, registry: ExternalDesktopRegistry(profile: profile))
        return max(0, external.spaces.count - saved.spaces.count)
    }

    /// False is an unchanged inventory. Every partial move or unrelated change throws.
    public static func isVerified(before: DesktopSnapshot, after: DesktopSnapshot, step: OrdinaryDesktopReturnStep) throws -> Bool {
        try validateDisplays(before); try validateDisplays(after)
        guard try before.topology() == .external(displayID: step.targetDisplayID), try before.topology() == after.topology(),
              let source = before.displays.first(where: { $0.id == step.sourceDisplayID }),
              let target = before.displays.first(where: { $0.id == step.targetDisplayID && !$0.isBuiltIn }),
              target.spaces.allSatisfy({ $0.kind == .ordinary }),
              let moving = source.spaces.first(where: { $0.id == step.spaceID && $0.kind == .ordinary }),
              step.stableUUID == nil || step.stableUUID == moving.stableUUID,
              source.isBuiltIn || source.id == target.id,
              !source.isBuiltIn || target.spaces.count < OrdinaryDesktopAddition.maximumOrdinaryDesktops,
              !source.isBuiltIn || source.spaces.filter({ $0.kind == .ordinary }).count > 1 else { throw changed() }
        let insertionCount = target.spaces.count - (source.id == target.id ? 1 : 0)
        guard step.targetIndex >= 0, step.targetIndex <= insertionCount else { throw changed() }
        var expected = before.displays.map(\.spaces)
        guard let sourceIndex = before.displays.firstIndex(where: { $0.id == source.id }),
              let targetIndex = before.displays.firstIndex(where: { $0.id == target.id }) else { throw changed() }
        expected[sourceIndex].removeAll { $0.id == moving.id }
        expected[targetIndex].insert(moving, at: step.targetIndex)
        var unchanged = true
        for display in before.displays {
            guard let observed = after.displays.first(where: { $0.id == display.id }),
                  observed.isBuiltIn == display.isBuiltIn, observed.frame == display.frame else { throw changed() }
            if observed.spaces != display.spaces { unchanged = false }
        }
        if unchanged { return false }
        for (index, display) in before.displays.enumerated() {
            guard after.displays.first(where: { $0.id == display.id })?.spaces == expected[index] else { throw changed() }
        }
        return true
    }

    private static func context(profile: LayoutProfile, snapshot: DesktopSnapshot, registry: ExternalDesktopRegistry) throws -> (SavedDisplay, DisplaySnapshot) {
        try profile.validate(); try registry.validate(profile: profile); try validateDisplays(snapshot)
        guard registry.matches(profile: profile), try snapshot.topology() == profile.topology,
              let saved = profile.displays.first(where: { $0.role == .external(id: registry.displayID) }),
              let external = snapshot.displays.first(where: { $0.id == registry.displayID && !$0.isBuiltIn }) else {
            throw changed("El registro de escritorios no corresponde a esta captura y monitor.")
        }
        return (saved, external)
    }

    private static func resolve(slot: Int, saved: SavedDisplay, snapshot: DesktopSnapshot, registry: ExternalDesktopRegistry, sessionID: UUID) throws -> (display: DisplaySnapshot, space: SpaceSnapshot)? {
        let evidence = registry.slots[slot]
        let identities = [saved.spaceUUIDs?[slot], evidence.stableUUID, evidence.createdUUID].compactMap { $0 }
        for uuid in identities {
            for display in snapshot.displays {
                if let space = display.spaces.first(where: { $0.stableUUID == uuid }) { return (display, space) }
            }
        }
        if evidence.sessionID == sessionID, let id = evidence.sessionSpaceID {
            for display in snapshot.displays {
                if let space = display.spaces.first(where: { $0.id == id }),
                   evidence.sessionSpaceUUID == space.stableUUID { return (display, space) }
            }
        }
        return nil
    }

    private static func validateDisplays(_ snapshot: DesktopSnapshot) throws {
        _ = try snapshot.topology()
        guard snapshot.hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
        let spaces = snapshot.displays.flatMap(\.spaces)
        let uuids = spaces.compactMap(\.stableUUID)
        guard snapshot.isComplete, snapshot.displays.allSatisfy({ $0.frame.isValid && !$0.spaces.isEmpty }),
              spaces.allSatisfy({ $0.id > 0 && $0.kind != .unknown }), Set(spaces.map(\.id)).count == spaces.count,
              Set(uuids).count == uuids.count else { throw changed("No se pudo comprobar una identidad única para cada escritorio.") }
    }

    private static func changed(_ reason: String = "La devolución cambió escritorios distintos del previsto; se detiene la recuperación.") -> MacTopCoreError {
        .invalidSnapshot(reason)
    }
}
