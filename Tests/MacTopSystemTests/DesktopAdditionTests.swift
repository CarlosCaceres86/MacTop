import MacTopCore
import XCTest

@testable import MacTopSystem

final class DesktopAdditionTests: XCTestCase {
  @MainActor
  func testAddsOnceAndReturnsVerifiedReferenceAfterAnimation() async throws {
    let before = state(external: [2])
    let after = state(external: [2, 3])
    var reads = [before, before, before, after]
    var presses = 0
    var closes = 0
    let result = try await DesktopAdditionExecution.execute(
      displayID: "external", expected: before,
      snapshot: { reads.removeFirst() }, open: { true }, close: { closes += 1 },
      press: { presses += 1 }, pause: {}, attempts: 3)
    XCTAssertEqual(result.displays, after.displays)
    XCTAssertEqual(presses, 1)
    XCTAssertEqual(closes, 1)
    XCTAssertTrue(reads.isEmpty)
  }

  @MainActor
  func testDoesNotCloseMissionControlThatWasAlreadyOpen() async throws {
    let before = state(external: [2])
    var reads = [before, before, state(external: [2, 3])]
    var closes = 0
    _ = try await DesktopAdditionExecution.execute(
      displayID: "external", expected: before,
      snapshot: { reads.removeFirst() }, open: { false }, close: { closes += 1 },
      press: {}, pause: {}, attempts: 1)
    XCTAssertEqual(closes, 0)
  }

  @MainActor
  func testUnchangedAfterPressStopsWithoutRetrying() async {
    let before = state(external: [2])
    var presses = 0
    do {
      _ = try await DesktopAdditionExecution.execute(
        displayID: "external", expected: before, snapshot: { before },
        open: { true }, close: {}, press: { presses += 1 }, pause: {}, attempts: 2)
      XCTFail("An issued click without an observed addition cannot succeed")
    } catch {}
    XCTAssertEqual(presses, 1)
  }

  @MainActor
  func testWrongDisplayAdditionFailsAndDoesNotPressAgain() async {
    let before = state(external: [2])
    var reads = [before, before, state(external: [2], builtIn: [1, 3])]
    var presses = 0
    do {
      _ = try await DesktopAdditionExecution.execute(
        displayID: "external", expected: before, snapshot: { reads.removeFirst() },
        open: { true }, close: {}, press: { presses += 1 }, pause: {}, attempts: 2)
      XCTFail("A new Space on the integrated display must be rejected")
    } catch {}
    XCTAssertEqual(presses, 1)
    XCTAssertTrue(reads.isEmpty)
  }

  @MainActor
  func testChangedTopologyDuringOpeningStopsBeforePress() async {
    let before = state(external: [2])
    var reads = [before, state(external: [2, 3])]
    var presses = 0
    var closes = 0
    do {
      _ = try await DesktopAdditionExecution.execute(
        displayID: "external", expected: before, snapshot: { reads.removeFirst() },
        open: { true }, close: { closes += 1 }, press: { presses += 1 }, pause: {}, attempts: 1)
      XCTFail("The reference became stale while Mission Control opened")
    } catch {}
    XCTAssertEqual(presses, 0)
    XCTAssertEqual(closes, 1)
  }

  @MainActor
  func testAXErrorStillReadsAndAcceptsExactlyOneObservedAddition() async throws {
    let before = state(external: [2])
    let after = state(external: [2, 3])
    var reads = [before, before, after]
    var presses = 0
    let result = try await DesktopAdditionExecution.execute(
      displayID: "external", expected: before, snapshot: { reads.removeFirst() },
      open: { true }, close: {},
      press: { presses += 1; throw SystemFailure.partial("AX timeout") }, pause: {}, attempts: 1)
    XCTAssertEqual(result.displays, after.displays)
    XCTAssertEqual(presses, 1)
  }

  @MainActor
  func testCancellationBeforePressClosesOnlyOurMissionControl() async {
    let before = state(external: [2])
    var presses = 0
    var closes = 0
    let task = Task { @MainActor in
      try await DesktopAdditionExecution.execute(
        displayID: "external", expected: before, snapshot: { before },
        open: { withUnsafeCurrentTask { $0?.cancel() }; return true },
        close: { closes += 1 }, press: { presses += 1 }, pause: {}, attempts: 1)
    }
    do { _ = try await task.value; XCTFail("Cancellation must stop the click") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(presses, 0)
    XCTAssertEqual(closes, 1)
  }

  @MainActor
  func testCancellationAfterPressStillObservesIssuedAddition() async throws {
    let before = state(external: [2])
    let after = state(external: [2, 3])
    var reads = [before, before, before, after]
    var presses = 0
    let task = Task { @MainActor in
      try await DesktopAdditionExecution.execute(
        displayID: "external", expected: before, snapshot: { reads.removeFirst() },
        open: { true }, close: {},
        press: { presses += 1; withUnsafeCurrentTask { $0?.cancel() } },
        pause: {}, attempts: 2)
    }
    do { _ = try await task.value; XCTFail("The caller must see cancellation after readback") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(reads.isEmpty)
    XCTAssertEqual(presses, 1)
  }

  func testHostPreferenceUsesDockOn26AndWindowManagerOn27() {
    XCTAssertEqual(MissionControlAccessibility.hostBundleIDs(majorVersion: 26).first, "com.apple.dock")
    XCTAssertEqual(MissionControlAccessibility.hostBundleIDs(majorVersion: 27).first, "com.apple.WindowManager")
  }

  func testDisplayAssociationRejectsWrongIDAndAmbiguousGeometry() throws {
    let frames = [UInt32(10): CGRect(x: 0, y: 0, width: 1440, height: 900),
                  UInt32(20): CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
    let groups = [MissionControlDisplayGroup(displayID: 10, frame: frames[10]),
                  MissionControlDisplayGroup(displayID: 20, frame: frames[20])]
    XCTAssertEqual(try missionControlDisplayIndex(target: 20, groups: groups, displays: frames), 1)
    XCTAssertThrowsError(try missionControlDisplayIndex(target: 30, groups: groups, displays: frames))
    let missingIDs = frames.keys.sorted().map { MissionControlDisplayGroup(displayID: nil, frame: frames[$0]) }
    XCTAssertEqual(try missionControlDisplayIndex(target: 20, groups: missingIDs, displays: frames), 1)
    XCTAssertThrowsError(try missionControlDisplayIndex(target: 20, groups: [missingIDs[0], missingIDs[0]], displays: frames))
    XCTAssertThrowsError(try missionControlDisplayIndex(target: 20, groups: [groups[0]], displays: frames))
  }

  private func state(external: [UInt64], builtIn: [UInt64] = [1]) -> DesktopSnapshot {
    DesktopSnapshot(displays: [
      .init(id: "built-in", isBuiltIn: true, frame: .init(x: 0, y: 0, width: 1440, height: 900),
            spaces: builtIn.map { .init(id: $0, kind: .ordinary) }),
      .init(id: "external", isBuiltIn: false, frame: .init(x: -1920, y: 0, width: 1920, height: 1080),
            spaces: external.map { .init(id: $0, kind: .ordinary) }),
    ], windows: [])
  }
}
