import Foundation

/// Checks only display state: windows may change independently while Mission Control is open.
public enum OrdinaryDesktopAddition {
    public static let maximumOrdinaryDesktops = 16

    public static func missingCount(profile: LayoutProfile, snapshot: DesktopSnapshot) throws -> Int {
        try profile.validate()
        try validateDisplays(snapshot)
        guard try snapshot.topology() == profile.topology else { return 0 }
        return try profile.displays.reduce(0) { count, saved in
            // Preserve the original single-external count while the complete planner handles all roles.
            if case .external = profile.topology, saved.role == .builtIn { return count }
            guard let current = snapshot.display(for: saved.role),
                  saved.spaces.allSatisfy({ $0 == .ordinary }), current.spaces.allSatisfy({ $0.kind == .ordinary }),
                  current.spaces.count < saved.spaces.count else { return count }
            guard saved.spaces.count <= maximumOrdinaryDesktops else {
                throw MacTopCoreError.invalidProfile(String(localized: "The profile exceeds the limit of 16 ordinary desktops per display; none was created."))
            }
            return count + saved.spaces.count - current.spaces.count
        }
    }

    /// False means a valid unchanged display inventory; every other unexpected delta throws.
    public static func isVerified(before: DesktopSnapshot, after: DesktopSnapshot, displayID: String) throws -> Bool {
        try validateDisplays(before)
        try validateDisplays(after)
        guard try before.topology() == after.topology(),
              let target = before.displays.first(where: { $0.id == displayID }),
              target.spaces.contains(where: { $0.kind == .ordinary }),
              target.spaces.filter({ $0.kind == .ordinary }).count < maximumOrdinaryDesktops,
              before.displays.count == after.displays.count else { throw changed() }
        var appended = false
        for display in before.displays {
            guard let observed = after.displays.first(where: { $0.id == display.id }),
                  observed.isBuiltIn == display.isBuiltIn, observed.frame == display.frame else { throw changed() }
            if observed.spaces == display.spaces { continue }
            guard display.id == displayID,
                  observed.spaces.count == display.spaces.count + 1,
                  Array(observed.spaces.dropLast()) == display.spaces,
                  observed.spaces.last?.kind == .ordinary else { throw changed() }
            appended = true
        }
        return appended
    }

    private static func validateDisplays(_ snapshot: DesktopSnapshot) throws {
        guard snapshot.hasAccessibilityPermission else { throw MacTopCoreError.missingPermission }
        _ = try snapshot.topology()
        let spaces = snapshot.displays.flatMap(\.spaces)
        let uuids = spaces.compactMap(\.stableUUID)
        guard Set(uuids).count == uuids.count, snapshot.isComplete, snapshot.displays.allSatisfy({ $0.frame.isValid && !$0.spaces.isEmpty }),
              spaces.allSatisfy({ $0.id > 0 && $0.kind != .unknown }),
              Set(spaces.map(\.id)).count == spaces.count else { throw changed() }
    }

    private static func changed() -> MacTopCoreError {
        .invalidSnapshot(String(localized: "The desktop sequence changed unexpectedly; no more desktops will be created."))
    }
}
