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

    public var role: DisplayRole { displayID.isEmpty ? .builtIn : .external(id: displayID) }

    public init(profile: LayoutProfile) throws {
        guard case let .external(id) = profile.topology else {
            throw MacTopCoreError.invalidProfile(String(localized: "The registry requires an external profile."))
        }
        try self.init(profile: profile, role: .external(id: id))
    }

    public init(profile: LayoutProfile, role: DisplayRole) throws {
        try profile.validate()
        guard let display = profile.displays.first(where: { $0.role == role }) else {
            throw MacTopCoreError.invalidProfile(String(localized: "The registry does not identify a saved display."))
        }
        switch role {
        case .builtIn: displayID = ""
        case let .external(id): displayID = id
        }
        capturedAt = profile.capturedAt
        slots = display.spaces.indices.map { ExternalDesktopIdentity(stableUUID: display.spaceUUIDs?[$0]) }
    }

    /// Only explicit "Save this layout" may seed live IDs by the observed ordinal.
    public init(profile: LayoutProfile, snapshot: DesktopSnapshot, sessionID: UUID) throws {
        try self.init(profile: profile)
        try seed(profile: profile, snapshot: snapshot, sessionID: sessionID)
    }

    public init(profile: LayoutProfile, role: DisplayRole, snapshot: DesktopSnapshot, sessionID: UUID) throws {
        try self.init(profile: profile, role: role)
        try seed(profile: profile, snapshot: snapshot, sessionID: sessionID)
    }

    private mutating func seed(profile: LayoutProfile, snapshot: DesktopSnapshot, sessionID: UUID) throws {
        let captured = try LayoutProfile.capture(snapshot: snapshot)
        guard captured.topology == profile.topology, captured.displays == profile.displays,
              let display = snapshot.display(for: role) else {
            throw MacTopCoreError.invalidSnapshot(String(localized: "The snapshot changed before its desktops were registered."))
        }
        for index in slots.indices {
            slots[index].sessionSpaceID = display.spaces[index].id
            slots[index].sessionSpaceUUID = display.spaces[index].stableUUID
            slots[index].sessionID = sessionID
        }
    }

    public func matches(profile: LayoutProfile) -> Bool {
        guard let saved = profile.displays.first(where: { $0.role == role }) else { return false }
        return capturedAt == profile.capturedAt && slots.count == saved.spaces.count
    }

    func validate(profile: LayoutProfile) throws {
        try profile.validate()
        guard matches(profile: profile),
              let saved = profile.displays.first(where: { $0.role == role }) else {
            throw MacTopCoreError.invalidProfile(String(localized: "The desktop registry does not match this snapshot and monitor."))
        }
        var identities = Set<UUID>()
        for (index, slot) in slots.enumerated() {
            guard slot.stableUUID == saved.spaceUUIDs?[index],
                  (slot.sessionSpaceID == nil) == (slot.sessionID == nil),
                  slot.sessionSpaceID == nil || slot.sessionSpaceID! > 0 else {
                throw MacTopCoreError.invalidProfile(String(localized: "The registry contains an inconsistent desktop identity."))
            }
            for uuid in Set([slot.stableUUID, slot.createdUUID].compactMap { $0 }) {
                guard identities.insert(uuid).inserted else {
                    throw MacTopCoreError.invalidProfile(String(localized: "The registry contains duplicate desktop identities."))
                }
            }
        }
    }

    /// Records only the newly appended Space after an exact, verified addition.
    public mutating func recordCreated(before: DesktopSnapshot, after: DesktopSnapshot, slot: Int, sessionID: UUID) throws {
        guard slots.indices.contains(slot), let liveDisplayID = before.display(for: role)?.id,
              try OrdinaryDesktopAddition.isVerified(before: before, after: after, displayID: liveDisplayID),
              let space = after.displays.first(where: { $0.id == liveDisplayID })?.spaces.last else {
            throw MacTopCoreError.invalidSnapshot(String(localized: "Could not register the created desktop."))
        }
        let previous = slots[slot]
        let originalUUIDs = [previous.stableUUID, previous.createdUUID].compactMap { $0 }
        let alreadyKnown = before.displays.flatMap(\.spaces).contains { existing in
            if let uuid = existing.stableUUID, originalUUIDs.contains(uuid) { return true }
            return previous.sessionID == sessionID && previous.sessionSpaceID == existing.id &&
                previous.sessionSpaceUUID == existing.stableUUID
        }
        guard !alreadyKnown else {
            throw MacTopCoreError.invalidSnapshot(String(localized: "The destination already has an identified desktop; its identity is preserved."))
        }
        let uuids = after.displays.flatMap(\.spaces).compactMap(\.stableUUID)
        if let uuid = space.stableUUID, uuids.filter({ $0 == uuid }).count != 1 {
            throw MacTopCoreError.invalidSnapshot(String(localized: "The created desktop UUID is duplicated."))
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
    case create(displayID: String, slot: Int?, reason: String)
    case ready
}

public enum OrdinaryDesktopReturn {
    private struct Destination {
        let display: DisplaySnapshot
        let saved: SavedDisplay
        let registry: ExternalDesktopRegistry
    }
    private struct Located {
        let display: DisplaySnapshot
        let space: SpaceSnapshot
    }

    public static func nextStep(profile: LayoutProfile, snapshot: DesktopSnapshot, registry: ExternalDesktopRegistry, sessionID: UUID) throws -> ExternalDesktopRecoveryStep {
        try plan(profile: profile, snapshot: snapshot, registries: [registry], sessionID: sessionID, complete: false)
    }

    public static func nextStep(profile: LayoutProfile, snapshot: DesktopSnapshot, registries: [ExternalDesktopRegistry], sessionID: UUID) throws -> ExternalDesktopRecoveryStep {
        try plan(profile: profile, snapshot: snapshot, registries: registries, sessionID: sessionID, complete: true)
    }

    private static func plan(profile: LayoutProfile, snapshot: DesktopSnapshot, registries: [ExternalDesktopRegistry], sessionID: UUID, complete: Bool) throws -> ExternalDesktopRecoveryStep {
        let destinations = try context(profile: profile, snapshot: snapshot, registries: registries, complete: complete)
        let (resolved, reserved) = try resolve(destinations: destinations, profile: profile, snapshot: snapshot, sessionID: sessionID)
        var blocked: [OrdinaryDesktopReturnStep] = []
        var unsupported = false
        var missing: [(display: DisplaySnapshot, slot: Int)] = []
        for (index, destination) in destinations.enumerated() {
            let target = destination.display
            // Mixed Mission Control sequences retain their existing ordinal semantics.
            guard destination.saved.spaces.allSatisfy({ $0 == .ordinary }), target.spaces.allSatisfy({ $0.kind == .ordinary }) else {
                if destination.saved.spaces != target.spaces.map(\.kind) || destination.saved.spaces.indices.contains(where: { slot in
                    guard let known = resolved[index][slot] else { return false }
                    return known.display.id != target.id || target.spaces[slot].id != known.space.id
                }) { unsupported = true }
                continue
            }
            var available = target.spaces.filter { !reserved.contains($0.id) }.makeIterator()
            for slot in destination.saved.spaces.indices {
                let location: Located?
                if let known = resolved[index][slot] { location = known }
                else { location = available.next().map { Located(display: target, space: $0) } }
                guard let location else { missing.append((target, slot)); continue }
                let source = location.display
                let insertionCount = target.spaces.count - (source.id == target.id ? 1 : 0)
                let targetIndex = min(slot, insertionCount)
                if source.id == target.id, target.spaces.firstIndex(where: { $0.id == location.space.id }) == targetIndex { continue }
                guard location.space.kind == .ordinary else { throw changed(String(localized: "An identified destination is no longer an ordinary desktop.")) }
                let step = OrdinaryDesktopReturnStep(spaceID: location.space.id, stableUUID: location.space.stableUUID,
                    sourceDisplayID: source.id, targetDisplayID: target.id, targetIndex: targetIndex, slot: slot)
                if source.id == target.id || (source.spaces.allSatisfy({ $0.kind == .ordinary }) && source.spaces.count > 1 && target.spaces.count < OrdinaryDesktopAddition.maximumOrdinaryDesktops) {
                    return .move(step)
                }
                blocked.append(step)
            }
        }
        guard !unsupported else {
            throw changed(String(localized: "A display with full-screen or Split View spaces no longer matches its saved destinations. Restore its desktop sequence manually before retrying."))
        }
        // Creating a genuinely missing destination can also release a sole-desktop source.
        for item in missing where item.display.spaces.count < OrdinaryDesktopAddition.maximumOrdinaryDesktops {
            return .create(displayID: item.display.id, slot: item.slot, reason: String(localized: "No available original desktop has been identified for this destination; the missing desktop will be created."))
        }
        if complete {
            for step in blocked {
                guard let source = snapshot.displays.first(where: { $0.id == step.sourceDisplayID }),
                      let target = snapshot.displays.first(where: { $0.id == step.targetDisplayID }), source.id != target.id,
                      source.spaces.allSatisfy({ $0.kind == .ordinary }), source.spaces.count == 1,
                      target.spaces.count < OrdinaryDesktopAddition.maximumOrdinaryDesktops,
                      source.spaces.filter({ $0.kind == .ordinary }).count < OrdinaryDesktopAddition.maximumOrdinaryDesktops else { continue }
                return .create(displayID: source.id, slot: nil, reason: String(localized: "Added an empty desktop so the original can be returned safely."))
            }
        }
        guard blocked.isEmpty && missing.isEmpty else {
            throw changed(String(localized: "Keep an ordinary desktop on the source display and make room on the destination before retrying."))
        }
        return .ready
    }

    public static func identityIssues(profile: LayoutProfile, snapshot: DesktopSnapshot, registry: ExternalDesktopRegistry, sessionID: UUID) throws -> [String] {
        try issues(profile: profile, snapshot: snapshot, registries: [registry], sessionID: sessionID, complete: false)
    }

    public static func identityIssues(profile: LayoutProfile, snapshot: DesktopSnapshot, registries: [ExternalDesktopRegistry], sessionID: UUID) throws -> [String] {
        try issues(profile: profile, snapshot: snapshot, registries: registries, sessionID: sessionID, complete: true)
    }

    private static func issues(profile: LayoutProfile, snapshot: DesktopSnapshot, registries: [ExternalDesktopRegistry], sessionID: UUID, complete: Bool) throws -> [String] {
        let destinations = try context(profile: profile, snapshot: snapshot, registries: registries, complete: complete)
        _ = try resolve(destinations: destinations, profile: profile, snapshot: snapshot, sessionID: sessionID)
        let observed = Set(snapshot.displays.flatMap(\.spaces).compactMap(\.stableUUID))
        return destinations.flatMap { destination in
            destination.saved.spaces.indices.compactMap { slot -> String? in
                guard let uuid = destination.registry.slots[slot].stableUUID ?? destination.registry.slots[slot].createdUUID,
                      !observed.contains(uuid) else { return nil }
                return String(localized: "The original UUID for desktop \(slot + 1) is missing; the available ordinary destination will be used without deleting its saved identity.")
            }
        }
    }

    public static func extraDesktopCount(profile: LayoutProfile, snapshot: DesktopSnapshot) throws -> Int {
        try profile.validate(); try validateDisplays(snapshot)
        guard try snapshot.topology() == profile.topology else { throw changed() }
        return profile.displays.reduce(0) { total, saved in
            // Keep the legacy external-only note for a single-external profile.
            if case .external = profile.topology, saved.role == .builtIn { return total }
            return total + max(0, (snapshot.display(for: saved.role)?.spaces.count ?? 0) - saved.spaces.count)
        }
    }

    /// False is an unchanged inventory. Every partial move or unrelated change throws.
    public static func isVerified(before: DesktopSnapshot, after: DesktopSnapshot, step: OrdinaryDesktopReturnStep) throws -> Bool {
        try validateDisplays(before); try validateDisplays(after)
        guard try before.topology() == after.topology(),
              let source = before.displays.first(where: { $0.id == step.sourceDisplayID }),
              let target = before.displays.first(where: { $0.id == step.targetDisplayID }),
              target.spaces.allSatisfy({ $0.kind == .ordinary }),
              let moving = source.spaces.first(where: { $0.id == step.spaceID && $0.kind == .ordinary }),
              step.stableUUID == nil || step.stableUUID == moving.stableUUID,
              source.id == target.id || (target.spaces.count < OrdinaryDesktopAddition.maximumOrdinaryDesktops && source.spaces.filter({ $0.kind == .ordinary }).count > 1) else { throw changed() }
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

    private static func context(profile: LayoutProfile, snapshot: DesktopSnapshot, registries: [ExternalDesktopRegistry], complete: Bool) throws -> [Destination] {
        try profile.validate(); try validateDisplays(snapshot)
        guard try snapshot.topology() == profile.topology,
              !registries.isEmpty,
              !complete || (registries.count == profile.displays.count && profile.displays.allSatisfy { saved in registries.filter { $0.role == saved.role }.count == 1 }) else {
            throw changed(String(localized: "Recovery requires matching registries for every display in this topology."))
        }
        return try registries.map { registry in
            try registry.validate(profile: profile)
            guard let saved = profile.displays.first(where: { $0.role == registry.role }),
                  let live = snapshot.display(for: registry.role) else { throw changed() }
            guard !saved.spaces.allSatisfy({ $0 == .ordinary }) || saved.spaces.count <= OrdinaryDesktopAddition.maximumOrdinaryDesktops else {
                throw MacTopCoreError.invalidProfile(String(localized: "The profile exceeds the limit of 16 ordinary desktops per display; none was created."))
            }
            return Destination(display: live, saved: saved, registry: registry)
        }
    }

    private static func resolve(destinations: [Destination], profile: LayoutProfile, snapshot: DesktopSnapshot, sessionID: UUID) throws -> ([[Located?]], Set<UInt64>) {
        let live = snapshot.displays.flatMap { display in display.spaces.map { Located(display: display, space: $0) } }
        var result = destinations.map { Array<Located?>(repeating: nil, count: $0.saved.spaces.count) }
        var reserved = Set<UInt64>()
        let originals = Set(profile.displays.flatMap { $0.spaceUUIDs?.compactMap { $0 } ?? [] })
        // Originals on every role are reserved even when the legacy caller plans only one display.
        for location in live where location.space.stableUUID.map({ originals.contains($0) }) == true { reserved.insert(location.space.id) }
        var claims = Set<UInt64>()
        for tier in 0...2 {
            var tierClaims = Set<UInt64>()
            for (displayIndex, destination) in destinations.enumerated() {
                for slot in destination.saved.spaces.indices {
                    let evidence = destination.registry.slots[slot]
                    let location: Located?
                    switch tier {
                    case 0: location = evidence.stableUUID.flatMap { uuid in live.first { $0.space.stableUUID == uuid } }
                    case 1: location = evidence.createdUUID.flatMap { uuid in live.first { $0.space.stableUUID == uuid && !originals.contains(uuid) } }
                    default:
                        if evidence.sessionID == sessionID, let id = evidence.sessionSpaceID, let candidate = live.first(where: { $0.space.id == id }) {
                            location = candidate.space.stableUUID == evidence.sessionSpaceUUID ? candidate : nil
                        } else { location = nil }
                    }
                    guard let location else { continue }
                    reserved.insert(location.space.id)
                    if tier > 0 && claims.contains(location.space.id) { continue }
                    guard tierClaims.insert(location.space.id).inserted else {
                        throw changed(String(localized: "Two saved destinations claim the same desktop identity."))
                    }
                    if result[displayIndex][slot] == nil {
                        result[displayIndex][slot] = location
                    }
                }
            }
            claims.formUnion(tierClaims)
        }
        return (result, reserved)
    }

    private static func validateDisplays(_ snapshot: DesktopSnapshot) throws {
        _ = try snapshot.topology()
        guard snapshot.hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
        let spaces = snapshot.displays.flatMap(\.spaces)
        let uuids = spaces.compactMap(\.stableUUID)
        guard snapshot.isComplete, snapshot.displays.allSatisfy({ $0.frame.isValid && !$0.spaces.isEmpty }),
              spaces.allSatisfy({ $0.id > 0 && $0.kind != .unknown }), Set(spaces.map(\.id)).count == spaces.count,
              Set(uuids).count == uuids.count else { throw changed(String(localized: "Could not verify a unique identity for each desktop.")) }
    }

    private static func changed(_ reason: String = String(localized: "The return changed desktops other than the intended one; recovery has stopped.")) -> MacTopCoreError {
        .invalidSnapshot(reason)
    }
}
