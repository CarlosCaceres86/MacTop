import Foundation

public struct SavedDisplay: Codable, Equatable, Sendable {
    public let role: DisplayRole
    public let spaces: [SpaceKind]
    public let spaceUUIDs: [UUID?]?

    public init(role: DisplayRole, spaces: [SpaceKind], spaceUUIDs: [UUID?]? = nil) {
        self.role = role; self.spaces = spaces; self.spaceUUIDs = spaceUUIDs
    }
}

public struct WindowDestination: Codable, Equatable, Sendable {
    public let display: DisplayRole
    /// Zero-based position in this display's full Mission Control sequence.
    public let spaceIndex: Int
    public let kind: SpaceKind

    public init(display: DisplayRole, spaceIndex: Int, kind: SpaceKind) {
        self.display = display; self.spaceIndex = spaceIndex; self.kind = kind
    }
}

public struct SavedWindow: Codable, Equatable, Sendable {
    public let identity: WindowIdentity
    public let title: String
    public let destination: WindowDestination?
    public let pendingReason: PendingReason?

    public init(identity: WindowIdentity, title: String, destination: WindowDestination?, pendingReason: PendingReason? = nil) {
        self.identity = identity; self.title = title
        self.destination = destination; self.pendingReason = pendingReason
    }
}

public struct LayoutProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let capturedAt: Date
    public let topology: ProfileTopology
    public let displays: [SavedDisplay]
    public let windows: [SavedWindow]

    public init(schemaVersion: Int = 1, capturedAt: Date = Date(), topology: ProfileTopology, displays: [SavedDisplay], windows: [SavedWindow]) {
        self.schemaVersion = schemaVersion; self.capturedAt = capturedAt
        self.topology = topology; self.displays = displays; self.windows = windows
    }

    public static func capture(snapshot: DesktopSnapshot) throws -> LayoutProfile {
        try snapshot.validate()
        let topology = try snapshot.topology()
        let uuids = snapshot.displays.flatMap(\.spaces).compactMap(\.stableUUID)
        let displays = snapshot.displays.map { display in
            SavedDisplay(role: display.isBuiltIn ? .builtIn : .external(id: display.id), spaces: display.spaces.map(\.kind),
                spaceUUIDs: display.spaces.map { space in
                    space.stableUUID.flatMap { uuid in uuids.filter { $0 == uuid }.count == 1 ? uuid : nil }
                })
        }
        let windows = snapshot.windows.map { window -> SavedWindow in
            let reason = windowProblem(window, snapshot: snapshot)
            guard reason == nil, let id = window.spaceIDs.first,
                  let display = snapshot.displays.first(where: { $0.spaces.contains(where: { $0.id == id }) }),
                  let index = display.spaces.firstIndex(where: { $0.id == id }) else {
                return SavedWindow(identity: window.identity, title: window.title, destination: nil, pendingReason: reason ?? .destinationMissing)
            }
            let destination = WindowDestination(display: display.isBuiltIn ? .builtIn : .external(id: display.id), spaceIndex: index, kind: display.spaces[index].kind)
            return SavedWindow(identity: window.identity, title: window.title, destination: destination)
        }
        guard windows.isEmpty || windows.contains(where: { $0.destination != nil }) else {
            throw MacTopCoreError.invalidSnapshot("No window has a verified destination; the previous profile is preserved.")
        }
        let result = LayoutProfile(topology: topology, displays: displays, windows: windows)
        try result.validate()
        return result
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw MacTopCoreError.invalidProfile("Unsupported profile version.") }
        let expectedRoles: [DisplayRole]
        switch topology {
        case .portable: expectedRoles = [.builtIn]
        case let .external(id):
            guard !id.isEmpty else { throw MacTopCoreError.invalidProfile("The saved monitor has no identity.") }
            expectedRoles = [.builtIn, .external(id: id)]
        }
        guard displays.count == expectedRoles.count,
              expectedRoles.allSatisfy({ role in displays.filter { $0.role == role }.count == 1 }),
              displays.allSatisfy({ !$0.spaces.isEmpty && !$0.spaces.contains(.unknown) }),
              Set(windows.map(\.identity)).count == windows.count else {
            throw MacTopCoreError.invalidProfile("The profile contains inconsistent displays or windows.")
        }
        let uuids = displays.flatMap { $0.spaceUUIDs?.compactMap { $0 } ?? [] }
        guard displays.allSatisfy({ $0.spaceUUIDs == nil || $0.spaceUUIDs?.count == $0.spaces.count }),
              Set(uuids).count == uuids.count else {
            throw MacTopCoreError.invalidProfile("The profile contains inconsistent desktop identities.")
        }
        for window in windows {
            guard let destination = window.destination else {
                guard window.pendingReason != nil else { throw MacTopCoreError.invalidProfile("A window has neither a destination nor a pending reason.") }
                continue
            }
            guard window.pendingReason == nil,
                  let display = displays.first(where: { $0.role == destination.display }),
                  display.spaces.indices.contains(destination.spaceIndex),
                  display.spaces[destination.spaceIndex] == destination.kind,
                  destination.kind == .ordinary,
                  window.identity.process.pid > 0, window.identity.windowID > 0,
                  !window.identity.bundleIdentifier.isEmpty else {
                throw MacTopCoreError.invalidProfile("A window destination does not match the saved sequence.")
            }
        }
    }
}

/// A window is handled only when both its Space membership and physical display are known.
func windowProblem(_ window: WindowSnapshot, snapshot: DesktopSnapshot, requireMembershipGeometry: Bool = true) -> PendingReason? {
    guard window.verificationIssue == nil, window.identity.process.pid > 0,
          window.identity.windowID > 0, !window.identity.bundleIdentifier.isEmpty else { return .unverifiedWindow }
    guard window.spaceIDs.count == 1 else { return .nonExclusiveMembership }
    guard let display = snapshot.displays.first(where: { $0.spaces.contains(where: { $0.id == window.spaceIDs[0] }) }),
          let space = display.spaces.first(where: { $0.id == window.spaceIDs[0] }) else { return .destinationMissing }
    guard space.kind == .ordinary else { return .unsupportedSpaceKind }
    guard snapshot.displays.filter({ $0.frame.containsCenter(of: window.frame) }).count == 1,
          !requireMembershipGeometry || display.frame.containsCenter(of: window.frame) else { return .geometryUnverified }
    return nil
}
