import Foundation
import MacTopCore

@MainActor
enum DesktopPlacementExecution {
  static func execute(
    step: OrdinaryDesktopReturnStep, expected: DesktopSnapshot,
    snapshot: () async throws -> DesktopSnapshot,
    open: () async throws -> Bool, close: () async throws -> Void,
    activate: (UInt64, String, DesktopSnapshot) throws -> Void,
    drag: (OrdinaryDesktopReturnStep, DesktopSnapshot) async throws -> Void,
    resumeAfterActivation: (() async throws -> Void)? = nil,
    pause: () async -> Void = MissionControlAccessibility.pause, attempts: Int = 30
  ) async throws -> DesktopSnapshot {
    try Task.checkCancellation()
    var current = try await snapshot()
    try requireUnchanged(expected, current: current, step: step)
    let source = try sourceDisplay(step, in: current)
    if step.sourceDisplayID == step.targetDisplayID,
      source.spaces.firstIndex(where: { $0.id == step.spaceID }) == step.targetIndex { return current }
    let opened = try await open()
    do {
      current = try await snapshot()
      try requireUnchanged(expected, current: current, step: step)
      // A cross-display arrival at another ordinal can be corrected only after its complete delta is certified.
      var request = step
      var reference = current
      for operation in 0..<2 {
        if operation > 0 { current = try await snapshot() }
        try requireUnchanged(reference, current: current, step: request)
        current = try await makeInactive(
          request, reference: reference, current: current, snapshot: snapshot, open: open,
          activate: activate, resumeAfterActivation: resumeAfterActivation, pause: pause, attempts: attempts)
        guard current.displays.first(where: { $0.id == request.sourceDisplayID })?.currentSpaceID != request.spaceID else {
          throw SystemFailure.changed("El escritorio se activó antes del arrastre; se ha detenido la recuperación.")
        }
        try Task.checkCancellation()
        var dragFailure: Error?
        do { try await drag(request, current) } catch { dragFailure = error }
        let arrival = try await observe(
          request, before: reference, snapshot: snapshot, pause: pause, attempts: attempts,
          allowDifferentIndex: operation == 0 && request.sourceDisplayID != request.targetDisplayID,
          failure: dragFailure)
        try Task.checkCancellation()
        if !arrival.differentIndex {
          if opened { try await close() }
          return arrival.snapshot
        }
        reference = arrival.snapshot
        current = reference
        request = OrdinaryDesktopReturnStep(
          spaceID: step.spaceID, stableUUID: step.stableUUID,
          sourceDisplayID: step.targetDisplayID, targetDisplayID: step.targetDisplayID,
          targetIndex: step.targetIndex, slot: step.slot)
      }
      throw SystemFailure.partial("El escritorio llegó al monitor, pero no a la posición solicitada.")
    } catch {
      if opened { try? await close() }
      throw error
    }
  }

  static func requireUnchanged(_ expected: DesktopSnapshot, current: DesktopSnapshot, step: OrdinaryDesktopReturnStep) throws {
    guard try !OrdinaryDesktopReturn.isVerified(before: expected, after: current, step: step) else {
      throw SystemFailure.changed("El orden o la ubicación del escritorio cambió antes de actuar.")
    }
  }

  private static func sourceDisplay(_ step: OrdinaryDesktopReturnStep, in snapshot: DesktopSnapshot) throws -> DisplaySnapshot {
    guard let source = snapshot.displays.first(where: { $0.id == step.sourceDisplayID }),
      let target = snapshot.displays.first(where: { $0.id == step.targetDisplayID }),
      source.spaces.allSatisfy({ $0.kind == .ordinary }), target.spaces.allSatisfy({ $0.kind == .ordinary }),
      let active = source.currentSpaceID, source.spaces.contains(where: { $0.id == active }),
      source.spaces.count > 1 else {
      throw SystemFailure.unavailable("El traslado requiere escritorios ordinarios identificados, un escritorio activo conocido y un hermano existente en origen.")
    }
    return source
  }

  private static func makeInactive(
    _ step: OrdinaryDesktopReturnStep, reference: DesktopSnapshot, current: DesktopSnapshot,
    snapshot: () async throws -> DesktopSnapshot, open: () async throws -> Bool,
    activate: (UInt64, String, DesktopSnapshot) throws -> Void,
    resumeAfterActivation: (() async throws -> Void)?,
    pause: () async -> Void, attempts: Int
  ) async throws -> DesktopSnapshot {
    let source = try sourceDisplay(step, in: current)
    guard source.currentSpaceID == step.spaceID else { return current }
    guard let sibling = source.spaces.first(where: { $0.id != step.spaceID }) else {
      throw SystemFailure.unavailable("No se puede trasladar el último escritorio de su pantalla.")
    }
    try Task.checkCancellation()
    var switchFailure: Error?
    do { try activate(sibling.id, source.id, current) } catch { switchFailure = error }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    for attempt in 0..<attempts {
      let observed = try await snapshot()
      try requireUnchanged(reference, current: observed, step: step)
      if observed.displays.first(where: { $0.id == source.id })?.currentSpaceID == sibling.id {
        try Task.checkCancellation()
        if let resumeAfterActivation {
          if let switchFailure { throw switchFailure }
          try await resumeAfterActivation()
        } else {
          _ = try await open()
        }
        return observed
      }
      if ProcessInfo.processInfo.systemUptime >= deadline { break }
      if attempt + 1 < attempts { await pause() }
    }
    throw switchFailure ?? SystemFailure.partial("No se pudo comprobar la activación del escritorio hermano. No se ha arrastrado ninguno.")
  }

  private static func observe(
    _ step: OrdinaryDesktopReturnStep, before: DesktopSnapshot,
    snapshot: () async throws -> DesktopSnapshot, pause: () async -> Void, attempts: Int,
    allowDifferentIndex: Bool, failure: Error?
  ) async throws -> (snapshot: DesktopSnapshot, differentIndex: Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    for attempt in 0..<attempts {
      let observed = try await snapshot()
      do {
        if try OrdinaryDesktopReturn.isVerified(before: before, after: observed, step: step) {
          return (observed, false)
        }
      } catch {
        guard allowDifferentIndex,
          let index = observed.displays.first(where: { $0.id == step.targetDisplayID })?.spaces.firstIndex(where: { $0.id == step.spaceID }) else { throw error }
        let actual = OrdinaryDesktopReturnStep(
          spaceID: step.spaceID, stableUUID: step.stableUUID, sourceDisplayID: step.sourceDisplayID,
          targetDisplayID: step.targetDisplayID, targetIndex: index, slot: step.slot)
        guard try OrdinaryDesktopReturn.isVerified(before: before, after: observed, step: actual) else { throw error }
        return (observed, true)
      }
      if ProcessInfo.processInfo.systemUptime >= deadline { break }
      if attempt + 1 < attempts { await pause() }
    }
    throw failure ?? SystemFailure.partial("No se pudo comprobar el traslado del escritorio. No se repetirá el arrastre.")
  }
}
