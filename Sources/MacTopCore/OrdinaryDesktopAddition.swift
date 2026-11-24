import Foundation

/// Checks only display state: windows may change independently while Mission Control is open.
public enum OrdinaryDesktopAddition {
    public static let maximumOrdinaryDesktops = 16

    public static func missingCount(profile: LayoutProfile, snapshot: DesktopSnapshot) throws -> Int {
        try profile.validate()
        try validateDisplays(snapshot)
        guard case let .external(id) = profile.topology,
              try snapshot.topology() == profile.topology,
              let saved = profile.displays.first(where: { $0.role == .external(id: id) }),
              let current = snapshot.displays.first(where: { $0.id == id && !$0.isBuiltIn }),
              saved.spaces.allSatisfy({ $0 == .ordinary }),
              current.spaces.allSatisfy({ $0.kind == .ordinary }),
              current.spaces.count < saved.spaces.count else { return 0 }
        guard saved.spaces.count <= maximumOrdinaryDesktops else {
            throw MacTopCoreError.invalidProfile("El perfil supera el límite de 16 escritorios ordinarios por pantalla; no se ha creado ninguno.")
        }
        return saved.spaces.count - current.spaces.count
    }

    /// False means a valid unchanged display inventory; every other unexpected delta throws.
    public static func isVerified(before: DesktopSnapshot, after: DesktopSnapshot, displayID: String) throws -> Bool {
        try validateDisplays(before)
        try validateDisplays(after)
        guard try before.topology() == .external(displayID: displayID),
              try before.topology() == after.topology(),
              let target = before.displays.first(where: { $0.id == displayID && !$0.isBuiltIn }),
              target.spaces.allSatisfy({ $0.kind == .ordinary }),
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
        guard snapshot.isComplete, snapshot.displays.allSatisfy({ $0.frame.isValid && !$0.spaces.isEmpty }),
              spaces.allSatisfy({ $0.id > 0 && $0.kind != .unknown }),
              Set(spaces.map(\.id)).count == spaces.count else { throw changed() }
    }

    private static func changed() -> MacTopCoreError {
        .invalidSnapshot("La secuencia de escritorios cambió inesperadamente; no se crearán más escritorios.")
    }
}
