import MacTopCore
import XCTest

@testable import MacTopSystem

@MainActor
final class DesktopRecoverySessionTests: XCTestCase {
  func testThreePlacementsUseOnePhysicalOpeningAndOneFinalClose() async throws {
    let ui = RecoveryUI()
    let session = ui.session()
    for id in [UInt64(2), 4, 5] {
      _ = try await session.placeOrdinaryDesktop(ui.step(id), expected: ui.state)
    }
    XCTAssertEqual(ui.drags, 3)
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.closes, 0)
    try await session.finish()
    try await session.finish()
    XCTAssertEqual(ui.closes, 1)
    XCTAssertFalse(ui.present)
  }

  func testCreationAndPlacementShareOpening() async throws {
    let ui = RecoveryUI()
    let session = ui.session()
    _ = try await session.addOrdinaryDesktop(displayID: "external", expected: ui.state)
    _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.presses, 1)
    XCTAssertEqual(ui.drags, 1)
    XCTAssertEqual(ui.closes, 1)
  }

  func testUserOwnedMissionControlStaysOpenAfterVerifiedActivationReopensIt() async throws {
    let ui = RecoveryUI(present: true)
    ui.builtInActive = 2
    let session = ui.session()
    _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    try await session.finish()
    XCTAssertEqual(ui.activations, 1)
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.closes, 0)
    XCTAssertTrue(ui.present)
  }

  func testOurOwnershipIsNotAccumulatedOnReopen() async throws {
    let ui = RecoveryUI()
    ui.builtInActive = 2
    let session = ui.session()
    _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 2)
    XCTAssertEqual(ui.closes, 1)
  }

  func testManualCloseBetweenPlacementsAbortsWithoutReopening() async throws {
    let ui = RecoveryUI()
    let session = ui.session()
    _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    ui.present = false
    do {
      _ = try await session.placeOrdinaryDesktop(ui.step(4), expected: ui.state)
      XCTFail("Manual closure must stop recovery")
    } catch {}
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.drags, 1)
    XCTAssertEqual(ui.closes, 1)
  }

  func testAmbiguousActivationDoesNotAuthorizeReopeningEvenWithMatchingReadback() async throws {
    let ui = RecoveryUI()
    ui.builtInActive = 2
    ui.activationFails = true
    let session = ui.session()
    do {
      _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
      XCTFail("An ambiguous activation must not reopen Mission Control")
    } catch {}
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.drags, 0)
    XCTAssertEqual(ui.closes, 1)
  }

  func testActivationWithoutObservedSwitchDoesNotReopen() async throws {
    let ui = RecoveryUI()
    ui.builtInActive = 2
    ui.activationChangesSpace = false
    let session = ui.session()
    do {
      _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
      XCTFail("Readback must verify the sibling before reopening")
    } catch {}
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.drags, 0)
    XCTAssertEqual(ui.closes, 1)
  }

  func testCorrectionMayReopenOnlyAfterItsOwnVerifiedActivation() async throws {
    let ui = RecoveryUI()
    ui.wrongArrival = true
    let session = ui.session()
    _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    try await session.finish()
    XCTAssertEqual(ui.drags, 2)
    XCTAssertEqual(ui.activations, 1)
    XCTAssertEqual(ui.physicalOpens, 2)
    XCTAssertEqual(ui.external, [2, 3])
    XCTAssertEqual(ui.closes, 1)
  }

  func testNoOperationsAndNoopPlacementNeverOpenOrClose() async throws {
    let ui = RecoveryUI(present: true)
    let empty = ui.session()
    try await empty.finish()
    ui.builtIn = [1, 4, 5]
    ui.external = [3, 2]
    let noop = ui.session()
    let step = OrdinaryDesktopReturnStep(spaceID: 2, stableUUID: nil,
      sourceDisplayID: "external", targetDisplayID: "external", targetIndex: 1, slot: 0)
    _ = try await noop.placeOrdinaryDesktop(step, expected: ui.state)
    try await noop.finish()
    XCTAssertEqual(ui.openCalls, 0)
    XCTAssertEqual(ui.closes, 0)
    XCTAssertEqual(ui.drags, 0)
  }

  func testFailedDragCleansUpOnlyOnceAndPreventsFurtherGestures() async throws {
    let ui = RecoveryUI()
    ui.dragFails = true
    let session = ui.session()
    do { _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state); XCTFail("Expected failure") }
    catch {}
    try await session.finish()
    do { _ = try await session.addOrdinaryDesktop(displayID: "external", expected: ui.state); XCTFail("Finished session") }
    catch {}
    XCTAssertEqual(ui.closes, 1)
    XCTAssertEqual(ui.drags, 1)
    XCTAssertEqual(ui.presses, 0)
  }

  func testPreopenedSessionWithThreePlacementsNeverPhysicallyOpensOrCloses() async throws {
    let ui = RecoveryUI(present: true)
    let session = ui.session()
    for id in [UInt64(2), 4, 5] {
      _ = try await session.placeOrdinaryDesktop(ui.step(id), expected: ui.state)
    }
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 0)
    XCTAssertEqual(ui.closes, 0)
    XCTAssertTrue(ui.present)
  }

  func testCancellationBeforeFirstGestureDoesNotOpenOrClose() async throws {
    let ui = RecoveryUI()
    let session = ui.session()
    let task = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 0)
    XCTAssertEqual(ui.closes, 0)
    XCTAssertEqual(ui.drags, 0)
  }

  func testFailureInUserOwnedSessionLeavesMissionControlOpen() async throws {
    let ui = RecoveryUI(present: true)
    ui.dragFails = true
    let session = ui.session()
    do { _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state); XCTFail("Expected failure") }
    catch {}
    try await session.finish()
    XCTAssertEqual(ui.closes, 0)
    XCTAssertTrue(ui.present)
  }

  func testManualCloseBeforeAddDoesNotPressOrReopen() async throws {
    let ui = RecoveryUI()
    let session = ui.session()
    _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    ui.present = false
    do { _ = try await session.addOrdinaryDesktop(displayID: "external", expected: ui.state); XCTFail("Expected manual close failure") }
    catch {}
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.presses, 0)
    try await session.finish()
  }

  func testAmbiguousCorrectionActivationCannotReopen() async throws {
    let ui = RecoveryUI()
    ui.wrongArrival = true
    ui.activationFails = true
    let session = ui.session()
    do { _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state); XCTFail("Ambiguous correction must stop") }
    catch {}
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.drags, 1)
    XCTAssertEqual(ui.activations, 1)
    XCTAssertEqual(ui.closes, 1)
  }

  func testFailedOperationAndCloseReportTheirFailuresWithoutClosingTwice() async throws {
    let ui = RecoveryUI()
    ui.dragFails = true
    ui.closeFails = true
    let session = ui.session()
    do { _ = try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state); XCTFail("Expected drag failure") }
    catch { XCTAssertTrue(error.localizedDescription.contains("No drag effect")) }
    do { try await session.finish(); XCTFail("Cleanup failure must reach the coordinator") }
    catch { XCTAssertTrue(error.localizedDescription.contains("Close failed")) }
    try await session.finish()
    XCTAssertEqual(ui.closes, 1)
  }

  func testFinishDuringOpeningIsRejectedWithoutLosingOwnership() async throws {
    let ui = RecoveryUI()
    var releaseOpen: CheckedContinuation<Void, Never>?
    var openStarted: CheckedContinuation<Void, Never>?
    ui.openWait = {
      await withCheckedContinuation { continuation in
        releaseOpen = continuation
        openStarted?.resume()
      }
    }
    let session = ui.session()
    let task = Task { @MainActor in
      try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    }
    await withCheckedContinuation { openStarted = $0 }
    do { try await session.finish(); XCTFail("Must reject closing during an operation") } catch {}
    releaseOpen?.resume()
    _ = try await task.value
    try await session.finish()
    XCTAssertEqual(ui.physicalOpens, 1)
    XCTAssertEqual(ui.drags, 1)
    XCTAssertEqual(ui.closes, 1)
  }

  func testCancelledOperationWaitsForAsynchronousCleanup() async throws {
    let ui = RecoveryUI()
    ui.cancelAfterDrag = true
    var releaseClose: CheckedContinuation<Void, Never>?
    var closeStarted: CheckedContinuation<Void, Never>?
    var returned = false
    ui.closeWait = {
      await withCheckedContinuation { continuation in
        releaseClose = continuation
        closeStarted?.resume()
      }
    }
    let session = ui.session()
    let task = Task { @MainActor in
      defer { returned = true }
      do {
        return try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
      } catch {
        try await session.finish()
        throw error
      }
    }
    await withCheckedContinuation { closeStarted = $0 }
    XCTAssertFalse(returned)
    releaseClose?.resume()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(returned)
    XCTAssertEqual(ui.closes, 1)
  }

  func testCancellationAfterGestureCompletesReadbackAndCleansUp() async throws {
    let ui = RecoveryUI()
    ui.cancelAfterDrag = true
    let session = ui.session()
    let task = Task { @MainActor in
      try await session.placeOrdinaryDesktop(ui.step(2), expected: ui.state)
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    try await session.finish()
    XCTAssertEqual(ui.reads, 3)
    XCTAssertEqual(ui.external, [2, 3])
    XCTAssertEqual(ui.closes, 1)
  }
}

@MainActor
private final class RecoveryUI {
  var present: Bool
  var physicalOpens = 0
  var openCalls = 0
  var closes = 0
  var drags = 0
  var presses = 0
  var activations = 0
  var reads = 0
  var builtIn: [UInt64] = [1, 2, 4, 5]
  var external: [UInt64] = [3]
  var builtInActive: UInt64 = 1
  var externalActive: UInt64 = 3
  var activationFails = false
  var activationChangesSpace = true
  var dragFails = false
  var wrongArrival = false
  var cancelAfterDrag = false
  var closeFails = false
  var closeWait: (() async -> Void)?
  var openWait: (() async -> Void)?

  init(present: Bool = false) { self.present = present }

  var state: DesktopSnapshot {
    DesktopSnapshot(displays: [
      .init(id: "built-in", isBuiltIn: true, frame: .init(x: 0, y: 0, width: 1440, height: 900),
        spaces: builtIn.map { .init(id: $0, kind: .ordinary) }, currentSpaceID: builtInActive),
      .init(id: "external", isBuiltIn: false, frame: .init(x: -1920, y: 0, width: 1920, height: 1080),
        spaces: external.map { .init(id: $0, kind: .ordinary) }, currentSpaceID: externalActive)
    ], windows: [], includesWindowInventory: false)
  }

  func step(_ id: UInt64) -> OrdinaryDesktopReturnStep {
    .init(spaceID: id, stableUUID: nil, sourceDisplayID: "built-in",
      targetDisplayID: "external", targetIndex: 0, slot: 0)
  }

  func session() -> DesktopRecoverySession {
    DesktopRecoverySession(
      snapshot: { self.reads += 1; return self.state },
      open: { _ in
        self.openCalls += 1
        await self.openWait?()
        let opened = !self.present
        if opened { self.physicalOpens += 1; self.present = true }
        return opened
      }, requireOpen: { _ in try self.requirePresent() },
      close: {
        self.closes += 1
        await self.closeWait?()
        if self.closeFails { throw SystemFailure.partial("Close failed") }
        self.present = false
      },
      press: { _, _ in try self.requirePresent(); self.presses += 1; self.external.append(6) },
      activate: { id, display, _ in
        try self.requirePresent()
        self.activations += 1
        self.present = false
        if self.activationChangesSpace {
          if display == "built-in" { self.builtInActive = id } else { self.externalActive = id }
        }
        if self.activationFails { throw SystemFailure.partial("Ambiguous AX reply") }
      },
      drag: { step, _ in
        try self.requirePresent()
        self.drags += 1
        if self.dragFails { throw SystemFailure.partial("No drag effect") }
        if step.sourceDisplayID == "built-in" { self.builtIn.removeAll { $0 == step.spaceID } }
        else { self.external.removeAll { $0 == step.spaceID } }
        if self.wrongArrival && self.drags == 1 {
          self.external.append(step.spaceID); self.externalActive = step.spaceID
        } else { self.external.insert(step.spaceID, at: step.targetIndex) }
        if self.cancelAfterDrag { withUnsafeCurrentTask { $0?.cancel() } }
      }, pause: {}, attempts: 1)
  }

  private func requirePresent() throws {
    guard present else { throw SystemFailure.changed("Mission Control was closed") }
  }
}
