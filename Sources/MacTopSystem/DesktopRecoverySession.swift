import MacTopCore

// One recovery owns UI lifetime; each executor still owns validation and action readback.
@MainActor
package final class DesktopRecoverySession {
  private let snapshot: () async throws -> DesktopSnapshot
  private let open: (Int) async throws -> Bool
  private let requireOpen: (Int) async throws -> Void
  private let close: () async throws -> Void
  private let press: (String, DesktopSnapshot) throws -> Void
  private let activate: (UInt64, String, DesktopSnapshot) throws -> Void
  private let drag: (OrdinaryDesktopReturnStep, DesktopSnapshot) async throws -> Void
  private let begin: () throws -> Void
  private let end: () -> Void
  private let pause: () async -> Void
  private let attempts: Int
  private var started = false
  private var openedByUs = false
  private var finished = false
  private var operating = false

  init(
    snapshot: @escaping () async throws -> DesktopSnapshot,
    open: @escaping (Int) async throws -> Bool,
    requireOpen: @escaping (Int) async throws -> Void,
    close: @escaping () async throws -> Void,
    press: @escaping (String, DesktopSnapshot) throws -> Void,
    activate: @escaping (UInt64, String, DesktopSnapshot) throws -> Void,
    drag: @escaping (OrdinaryDesktopReturnStep, DesktopSnapshot) async throws -> Void,
    begin: @escaping () throws -> Void = {}, end: @escaping () -> Void = {},
    pause: @escaping () async -> Void = MissionControlAccessibility.pause,
    attempts: Int = 30
  ) {
    self.snapshot = snapshot; self.open = open; self.requireOpen = requireOpen
    self.close = close; self.press = press; self.activate = activate; self.drag = drag
    self.begin = begin; self.end = end; self.pause = pause; self.attempts = attempts
  }

  package func addOrdinaryDesktop(displayID: String, expected: DesktopSnapshot) async throws -> DesktopSnapshot {
    try startOperation()
    defer { operating = false; end() }
    return try await DesktopAdditionExecution.execute(
      displayID: displayID, expected: expected, snapshot: snapshot,
      open: { try await self.ensureOpen(displayCount: expected.displays.count) }, close: {},
      press: { try self.press(displayID, expected) }, pause: pause, attempts: attempts)
  }

  package func placeOrdinaryDesktop(_ step: OrdinaryDesktopReturnStep, expected: DesktopSnapshot) async throws -> DesktopSnapshot {
    try startOperation()
    defer { operating = false; end() }
    return try await DesktopPlacementExecution.execute(
      step: step, expected: expected, snapshot: snapshot,
      open: { try await self.ensureOpen(displayCount: expected.displays.count) }, close: {},
      activate: activate, drag: drag,
      resumeAfterActivation: { try await self.reopenAfterActivation(displayCount: expected.displays.count) },
      pause: pause, attempts: attempts)
  }

  package func finish() async throws {
    guard !operating else {
      throw SystemFailure.unavailable(String(localized: "Wait for the operation to finish before closing the recovery session."))
    }
    guard !finished else { return }
    finished = true
    if openedByUs { try await close() }
  }

  private func startOperation() throws {
    guard !finished, !operating else {
      throw SystemFailure.unavailable(String(localized: "The recovery session has ended or already has an operation in progress."))
    }
    try begin()
    operating = true
  }

  private func ensureOpen(displayCount: Int) async throws -> Bool {
    if started {
      // A disappearance between ordinary actions is user intervention, never an invitation to reopen.
      try await requireOpen(displayCount)
    } else {
      openedByUs = try await open(displayCount)
      started = true
    }
    return false
  }

  private func reopenAfterActivation(displayCount: Int) async throws {
    // The executor authorizes this only after an unambiguous press and verified sibling activation.
    _ = try await open(displayCount)
  }
}
