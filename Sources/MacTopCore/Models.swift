import Foundation

public struct WindowFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }

    public func containsCenter(of window: WindowFrame) -> Bool {
        guard isValid, window.isValid else { return false }
        let centerX = window.x + window.width / 2
        let centerY = window.y + window.height / 2
        return centerX >= x && centerX < x + width && centerY >= y && centerY < y + height
    }
}

public enum SpaceKind: String, Codable, Sendable {
    case ordinary, fullScreen, splitView, unknown

    var displayName: String {
        switch self {
        case .ordinary: return String(localized: "ordinary")
        case .fullScreen: return String(localized: "full screen")
        case .splitView: return String(localized: "Split View")
        case .unknown: return String(localized: "unknown")
        }
    }
}

public struct SpaceSnapshot: Codable, Equatable, Sendable {
    public let id: UInt64
    public let kind: SpaceKind
    public let stableUUID: UUID?

    public init(id: UInt64, kind: SpaceKind, stableUUID: UUID? = nil) {
        self.id = id; self.kind = kind
        self.stableUUID = stableUUID?.uuidString == "00000000-0000-0000-0000-000000000000" ? nil : stableUUID
    }
}

public struct DisplaySnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let isBuiltIn: Bool
    public let frame: WindowFrame
    public let spaces: [SpaceSnapshot]
    public let currentSpaceID: UInt64?
    public let localizedName: String?

    public init(id: String, isBuiltIn: Bool, frame: WindowFrame, spaces: [SpaceSnapshot], currentSpaceID: UInt64? = nil,
                localizedName: String? = nil) {
        self.id = id; self.isBuiltIn = isBuiltIn; self.frame = frame; self.spaces = spaces
        self.currentSpaceID = currentSpaceID
        self.localizedName = localizedName
    }
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let launchDate: Date

    public init(pid: Int32, launchDate: Date) {
        self.pid = pid; self.launchDate = launchDate
    }
}

public struct WindowIdentity: Codable, Hashable, Sendable {
    public let process: ProcessIdentity
    public let windowID: UInt32
    public let bundleIdentifier: String

    public init(process: ProcessIdentity, windowID: UInt32, bundleIdentifier: String) {
        self.process = process; self.windowID = windowID; self.bundleIdentifier = bundleIdentifier
    }
}

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public let identity: WindowIdentity
    public let title: String
    public let frame: WindowFrame
    public let spaceIDs: [UInt64]
    public let verificationIssue: String?

    public init(identity: WindowIdentity, title: String, frame: WindowFrame, spaceIDs: [UInt64], verificationIssue: String? = nil) {
        self.identity = identity; self.title = title; self.frame = frame
        self.spaceIDs = spaceIDs; self.verificationIssue = verificationIssue
    }
}

public enum ProfileTopology: Codable, Hashable, Sendable {
    case portable
    case external(displayID: String)
}

public enum DisplayRole: Codable, Equatable, Sendable {
    case builtIn
    case external(id: String)
}

public struct DesktopSnapshot: Codable, Equatable, Sendable {
    public let displays: [DisplaySnapshot]
    public let windows: [WindowSnapshot]
    public let hasAccessibilityPermission: Bool
    public let isComplete: Bool
    public let issues: [String]
    private let windowInventoryOmitted: Bool?

    public init(displays: [DisplaySnapshot], windows: [WindowSnapshot], hasAccessibilityPermission: Bool = true, isComplete: Bool = true, issues: [String] = [], includesWindowInventory: Bool = true) {
        self.displays = displays; self.windows = windows
        self.hasAccessibilityPermission = hasAccessibilityPermission
        self.isComplete = isComplete; self.issues = issues
        self.windowInventoryOmitted = includesWindowInventory ? nil : true
    }

    /// Switching the active Space changes no desktop ownership or order.
    public func hasSameDisplayStructure(as other: DesktopSnapshot) -> Bool {
        guard displays.count == other.displays.count,
              Set(displays.map(\.id)).count == displays.count,
              Set(other.displays.map(\.id)).count == other.displays.count else { return false }
        return displays.allSatisfy { display in
            guard let candidate = other.displays.first(where: { $0.id == display.id }) else { return false }
            return candidate.isBuiltIn == display.isBuiltIn && candidate.frame == display.frame && candidate.spaces == display.spaces
        }
    }

    public func topology() throws -> ProfileTopology {
        let builtIn = displays.filter(\.isBuiltIn)
        let external = displays.filter { !$0.isBuiltIn }
        guard builtIn.count == 1, external.count <= 1,
              !displays.contains(where: { $0.id.isEmpty }),
              Set(displays.map(\.id)).count == displays.count else {
            throw MacTopCoreError.unsupportedTopology
        }
        return external.first.map { .external(displayID: $0.id) } ?? .portable
    }

    func validate() throws {
        guard hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
        guard isComplete else { throw MacTopCoreError.invalidSnapshot(String(localized: "The inventory is incomplete.")) }
        guard windowInventoryOmitted != true else { throw MacTopCoreError.invalidSnapshot(String(localized: "The window inventory has not been read.")) }
        _ = try topology()
        guard displays.allSatisfy({ $0.frame.isValid && !$0.spaces.isEmpty && !$0.spaces.contains(where: { $0.id == 0 || $0.kind == .unknown }) }) else {
            throw MacTopCoreError.invalidSnapshot(String(localized: "Could not verify the desktop sequence on each display."))
        }
        let spaceIDs = displays.flatMap { $0.spaces.map(\.id) }
        guard Set(spaceIDs).count == spaceIDs.count,
              Set(windows.map(\.identity)).count == windows.count,
              Set(windows.map { $0.identity.windowID }).count == windows.count else {
            throw MacTopCoreError.invalidSnapshot(String(localized: "The inventory contains duplicate identities."))
        }
    }

    func display(for role: DisplayRole) -> DisplaySnapshot? {
        switch role {
        case .builtIn: return displays.first(where: \.isBuiltIn)
        case let .external(id): return displays.first { !$0.isBuiltIn && $0.id == id }
        }
    }
}

public enum MacTopCoreError: Error, LocalizedError {
    case unsupportedTopology
    case missingPermission
    case invalidSnapshot(String)
    case invalidProfile(String)
    case externalMonitorConflict(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTopology: return String(localized: "The built-in display and, optionally, one identified external monitor are required.")
        case .missingPermission: return String(localized: "Accessibility permission is missing.")
        case let .invalidSnapshot(message), let .invalidProfile(message): return message
        case let .externalMonitorConflict(id): return String(localized: "The external profile belongs to another monitor (\(id)); it was not replaced.")
        }
    }
}
