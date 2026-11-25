import Foundation
import MacTopCore

@MainActor
enum WindowMoveExecution {
  static func execute(
    move: WindowMove, expected: DesktopSnapshot,
    snapshot: () async throws -> DesktopSnapshot,
    validate: (DesktopSnapshot, DesktopSnapshot) throws -> Void,
    moveSpace: () async throws -> HelperReply,
    reposition: (WindowSnapshot, DesktopSnapshot) throws -> Void
  ) async throws {
    let before = try await snapshot()
    try validate(before, expected)
    guard let original = before.windows.first(where: { $0.identity == move.identity }) else {
      throw SystemFailure.changed("The original window no longer exists.")
    }
    let sourceDisplay = physicalDisplay(for: original.frame, in: before.displays)
    try Task.checkCancellation()
    var reply = try await moveSpace()
    // Cancellation never skips observation of an operation already issued.
    var after = try await snapshot()
    try validateAfter(after, before: before, validate: validate)
    guard let window = after.windows.first(where: { $0.identity == move.identity }) else {
      throw SystemFailure.partial("Could not observe the same window after the move.")
    }
    if window.spaceIDs != [move.spaceID] {
      guard let sourceDisplay, sourceDisplay != move.displayID else {
        throw membershipFailure(reply)
      }
      // Match upstream's bounded cross-display fallback: AX placement, then Space retry.
      try Task.checkCancellation()
      try reposition(window, after)
      after = try await snapshot()
      try validateAfter(after, before: before, validate: validate)
      try Task.checkCancellation()
      reply = try await moveSpace()
      after = try await snapshot()
    } else if physicalDisplay(for: window.frame, in: after.displays) != move.displayID {
      try Task.checkCancellation()
      try reposition(window, after)
      after = try await snapshot()
    }
    try validateAfter(after, before: before, validate: validate)
    guard let observed = after.windows.first(where: { $0.identity == move.identity }),
      observed.verificationIssue == nil, observed.spaceIDs == [move.spaceID],
      physicalDisplay(for: observed.frame, in: after.displays) == move.displayID
    else {
      throw SystemFailure.partial(
        "The move was partial: the window, physical display, and desktop do not match the intended destination."
      )
    }
  }

  private static func validateAfter(
    _ current: DesktopSnapshot, before: DesktopSnapshot,
    validate: (DesktopSnapshot, DesktopSnapshot) throws -> Void
  ) throws {
    do { try validate(current, before) } catch {
      throw SystemFailure.partial(
        "The identity, permissions, or configuration changed during the move. Restoration has stopped; check the result."
      )
    }
  }

  private static func membershipFailure(_ reply: HelperReply) -> SystemFailure {
    .partial(
      reply.timedOut
        ? "The component timed out; the window has not been verified at the destination."
        : "The window did not reach the intended desktop exclusively.")
  }
}
