import Foundation
import MacTopCore

enum DesktopAdditionExecution {
  @MainActor
  static func execute(
    displayID: String, expected: DesktopSnapshot,
    snapshot: () async throws -> DesktopSnapshot,
    open: () async throws -> Bool, close: () async throws -> Void,
    press: () throws -> Void,
    pause: () async -> Void = MissionControlAccessibility.pause,
    attempts: Int = 30
  ) async throws -> DesktopSnapshot {
    try Task.checkCancellation()
    try unchanged(expected, current: try await snapshot(), displayID: displayID)
    let opened = try await open()
    do {
      try unchanged(expected, current: try await snapshot(), displayID: displayID)
      try Task.checkCancellation()
      var pressFailure: Error?
      do { try press() } catch { pressFailure = error }
      // An AX reply is not a receipt. Observe even if AX failed or the task was cancelled.
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      for attempt in 0..<attempts {
        let observed = try await snapshot()
        if try OrdinaryDesktopAddition.isVerified(before: expected, after: observed, displayID: displayID) {
          try Task.checkCancellation()
          if opened { try await close() }
          return observed
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { break }
        if attempt + 1 < attempts { await pause() }
      }
      throw pressFailure ?? SystemFailure.partial(
        String(localized: "“+” was clicked, but a single new desktop on the target display could not be verified. The click will not be repeated."))
    } catch {
      if opened { try? await close() }
      throw error
    }
  }

  private static func unchanged(_ expected: DesktopSnapshot, current: DesktopSnapshot, displayID: String) throws {
    guard try !OrdinaryDesktopAddition.isVerified(before: expected, after: current, displayID: displayID) else {
      throw SystemFailure.changed(String(localized: "The desktops changed before “+” was clicked. Recalculate the restoration."))
    }
  }
}
