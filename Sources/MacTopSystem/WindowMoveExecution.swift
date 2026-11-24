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
      throw SystemFailure.changed("La ventana original ya no existe.")
    }
    let sourceDisplay = physicalDisplay(for: original.frame, in: before.displays)
    try Task.checkCancellation()
    var reply = try await moveSpace()
    // Cancellation never skips observation of an operation already issued.
    var after = try await snapshot()
    try validateAfter(after, before: before, validate: validate)
    guard let window = after.windows.first(where: { $0.identity == move.identity }) else {
      throw SystemFailure.partial("No se pudo observar la misma ventana después del movimiento.")
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
        "El movimiento quedó parcial: no coinciden la misma ventana, la pantalla física y el escritorio previstos."
      )
    }
  }

  private static func validateAfter(
    _ current: DesktopSnapshot, before: DesktopSnapshot,
    validate: (DesktopSnapshot, DesktopSnapshot) throws -> Void
  ) throws {
    do { try validate(current, before) } catch {
      throw SystemFailure.partial(
        "La identidad, los permisos o la configuración cambiaron durante el movimiento. Se ha detenido la restauración; revisa el resultado."
      )
    }
  }

  private static func membershipFailure(_ reply: HelperReply) -> SystemFailure {
    .partial(
      reply.timedOut
        ? "El componente agotó el tiempo de espera; la ventana no está verificada en el destino."
        : "La ventana no llegó exclusivamente al escritorio previsto.")
  }
}
