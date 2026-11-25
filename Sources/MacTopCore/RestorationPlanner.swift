import Foundation

public enum PendingReason: String, Codable, Sendable {
    case unverifiedWindow, nonExclusiveMembership, unsupportedSpaceKind, geometryUnverified
    case destinationMissing, applicationClosed, ambiguousWindow, windowUnavailable

    public var message: String {
        switch self {
        case .unverifiedWindow: return "The window identity or access has not been verified."
        case .nonExclusiveMembership: return "The window does not belong exclusively to one desktop."
        case .unsupportedSpaceKind: return "Full screen or Split View requires physical validation."
        case .geometryUnverified: return "The physical position does not match exactly one display in the inventory."
        case .destinationMissing: return "The destination display or desktop is missing."
        case .applicationClosed: return "The application is closed or has no available windows."
        case .ambiguousWindow: return "Multiple windows match; none was selected."
        case .windowUnavailable: return "The saved window is no longer available in this application instance."
        }
    }
}

public struct PendingWindow: Equatable, Sendable {
    public let identity: WindowIdentity
    public let reason: PendingReason

    public init(identity: WindowIdentity, reason: PendingReason) {
        self.identity = identity; self.reason = reason
    }
}

public struct WindowMove: Equatable, Sendable {
    public let identity: WindowIdentity
    // A uniquely matched window from a relaunched app has a different live identity.
    package let savedIdentity: WindowIdentity
    public let displayID: String
    public let spaceID: UInt64

    public init(identity: WindowIdentity, displayID: String, spaceID: UInt64) {
        self.init(identity: identity, savedIdentity: identity, displayID: displayID, spaceID: spaceID)
    }

    fileprivate init(identity: WindowIdentity, savedIdentity: WindowIdentity, displayID: String, spaceID: UInt64) {
        self.identity = identity
        self.savedIdentity = savedIdentity
        self.displayID = displayID
        self.spaceID = spaceID
    }
}

public struct RestorationPlan: Equatable, Sendable {
    public let moves: [WindowMove]
    public let pending: [PendingWindow]
    public let alreadyCorrect: Int
    public let issues: [String]
    public var hasWork: Bool { !moves.isEmpty }
    public var isComplete: Bool { moves.isEmpty && pending.isEmpty && issues.isEmpty }

    public init(moves: [WindowMove], pending: [PendingWindow], alreadyCorrect: Int, issues: [String] = []) {
        self.moves = moves; self.pending = pending; self.alreadyCorrect = alreadyCorrect; self.issues = issues
    }
}

public enum RestorationPlanner {
    public static func plan(profile: LayoutProfile, snapshot: DesktopSnapshot) -> RestorationPlan {
        do {
            try profile.validate()
            try snapshot.validate()
            guard try snapshot.topology() == profile.topology else {
                return RestorationPlan(moves: [], pending: [], alreadyCorrect: 0, issues: ["The display configuration does not match the profile."])
            }
        } catch {
            return RestorationPlan(moves: [], pending: [], alreadyCorrect: 0, issues: [error.localizedDescription] + snapshot.issues)
        }

        var issues = snapshot.issues
        for savedDisplay in profile.displays {
            guard let current = snapshot.display(for: savedDisplay.role) else {
                issues.append("A saved display is missing.")
                continue
            }
            for (index, kind) in savedDisplay.spaces.enumerated() {
                if !current.spaces.indices.contains(index) || current.spaces[index].kind != kind {
                    issues.append("Desktop \(index + 1) of type \(kind.rawValue) is missing on \(current.id).")
                }
            }
        }

        // Reserve exact identities first so a restart fallback never consumes another saved window.
        let currentByIdentity = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.identity, $0) })
        var matches: [WindowIdentity: WindowSnapshot] = [:]
        var used: Set<WindowIdentity> = []
        for saved in profile.windows {
            if let current = currentByIdentity[saved.identity] {
                matches[saved.identity] = current
                used.insert(current.identity)
            }
        }
        var reasons: [WindowIdentity: PendingReason] = [:]
        let unmatched = profile.windows.filter { matches[$0.identity] == nil && $0.destination != nil }
        for saved in unmatched {
            let sameBundle = snapshot.windows.filter { $0.identity.bundleIdentifier == saved.identity.bundleIdentifier }
            let candidates = sameBundle.filter { !used.contains($0.identity) }
            let pendingForBundle = unmatched.filter { $0.identity.bundleIdentifier == saved.identity.bundleIdentifier }
            if sameBundle.isEmpty {
                reasons[saved.identity] = .applicationClosed
            } else if sameBundle.contains(where: { $0.identity.process == saved.identity.process }) {
                // Window IDs may be recycled within a process; never infer a replacement in that instance.
                reasons[saved.identity] = .windowUnavailable
            } else if pendingForBundle.count == 1, candidates.count == 1 {
                matches[saved.identity] = candidates[0]
                used.insert(candidates[0].identity)
            } else {
                reasons[saved.identity] = .ambiguousWindow
            }
        }

        var moves: [WindowMove] = []
        var pending: [PendingWindow] = []
        var correct = 0
        for saved in profile.windows {
            guard let destination = saved.destination else {
                pending.append(PendingWindow(identity: saved.identity, reason: saved.pendingReason ?? .unverifiedWindow))
                continue
            }
            guard let display = snapshot.display(for: destination.display),
                  display.spaces.indices.contains(destination.spaceIndex),
                  display.spaces[destination.spaceIndex].kind == destination.kind else {
                pending.append(PendingWindow(identity: saved.identity, reason: .destinationMissing))
                continue
            }
            guard let window = matches[saved.identity] else {
                pending.append(PendingWindow(identity: saved.identity, reason: reasons[saved.identity] ?? .windowUnavailable))
                continue
            }
            if let reason = windowProblem(window, snapshot: snapshot, requireMembershipGeometry: false) {
                pending.append(PendingWindow(identity: saved.identity, reason: reason))
                continue
            }
            let move = WindowMove(identity: window.identity, savedIdentity: saved.identity, displayID: display.id,
                                  spaceID: display.spaces[destination.spaceIndex].id)
            if isRestored(move: move, snapshot: snapshot) { correct += 1 } else { moves.append(move) }
        }
        return RestorationPlan(moves: moves, pending: pending, alreadyCorrect: correct, issues: issues)
    }

    public static func isRestored(move: WindowMove, snapshot: DesktopSnapshot) -> Bool {
        guard (try? snapshot.validate()) != nil,
              let display = snapshot.displays.first(where: { $0.id == move.displayID }),
              display.spaces.contains(where: { $0.id == move.spaceID && $0.kind == .ordinary }),
              let window = snapshot.windows.first(where: { $0.identity == move.identity }),
              windowProblem(window, snapshot: snapshot) == nil else { return false }
        return window.spaceIDs == [move.spaceID] && display.frame.containsCenter(of: window.frame)
    }
}
