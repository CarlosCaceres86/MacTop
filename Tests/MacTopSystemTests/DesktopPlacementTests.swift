import ApplicationServices
import MacTopCore
import XCTest

@testable import MacTopSystem

final class DesktopPlacementTests: XCTestCase {
  private let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  @MainActor
  func testCrossDisplayArrivalAtWrongIndexGetsOneVerifiedLocalCorrection() async throws {
    let before = state(builtIn: [1, 2], external: [3])
    var observed = before
    var steps: [OrdinaryDesktopReturnStep] = []
    var closes = 0
    let result = try await DesktopPlacementExecution.execute(
      step: step, expected: before, snapshot: { observed }, open: { true }, close: { closes += 1 },
      activate: { _, _, _ in XCTFail("An inactive desktop requires no switch") },
      drag: { next, _ in
        steps.append(next)
        observed = steps.count == 1
          ? self.state(builtIn: [1], external: [3, 2]) : self.state(builtIn: [1], external: [2, 3])
      }, pause: {}, attempts: 1)
    XCTAssertEqual(result.displays.last?.spaces.map(\.id), [2, 3])
    XCTAssertEqual(steps.map(\.sourceDisplayID), ["built-in", "external"])
    XCTAssertEqual(steps.map(\.spaceID), [2, 2])
    XCTAssertEqual(closes, 1)
  }

  @MainActor
  func testNoEffectDoesNotRetryDrag() async {
    let before = state(builtIn: [1, 2], external: [3])
    var drags = 0
    do {
      _ = try await DesktopPlacementExecution.execute(
        step: step, expected: before, snapshot: { before }, open: { false }, close: {},
        activate: { _, _, _ in }, drag: { _, _ in drags += 1 }, pause: {}, attempts: 2)
      XCTFail("No observed relocation must fail")
    } catch {}
    XCTAssertEqual(drags, 1)
  }

  @MainActor
  func testUnrelatedDeltaStopsBeforeCorrection() async {
    let before = state(builtIn: [1, 2], external: [3])
    var observed = before
    var drags = 0
    do {
      _ = try await DesktopPlacementExecution.execute(
        step: step, expected: before, snapshot: { observed }, open: { true }, close: {},
        activate: { _, _, _ in },
        drag: { _, _ in drags += 1; observed = self.state(builtIn: [1, 9], external: [3, 2]) },
        pause: {}, attempts: 1)
      XCTFail("An extra desktop is not a certified arrival")
    } catch {}
    XCTAssertEqual(drags, 1)
  }

  @MainActor
  func testCancellationAfterDragObservesAndNeverCorrects() async {
    let before = state(builtIn: [1, 2], external: [3])
    var observed = before
    var reads = 0
    var drags = 0
    let operation = Task { @MainActor in
      try await DesktopPlacementExecution.execute(
        step: step, expected: before, snapshot: { reads += 1; return observed },
        open: { true }, close: {}, activate: { _, _, _ in },
        drag: { _, _ in
          drags += 1
          observed = self.state(builtIn: [1], external: [3, 2])
          withUnsafeCurrentTask { $0?.cancel() }
        }, pause: {}, attempts: 1)
    }
    do { _ = try await operation.value; XCTFail("Cancelled operation must stop") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(drags, 1)
    XCTAssertEqual(reads, 3)
  }

  @MainActor
  func testActiveSourceSwitchesToExistingSiblingAndReopensWithoutOwningUserMC() async throws {
    let before = state(builtIn: [1, 2], external: [3], current: 2)
    var observed = before
    var opens = 0
    var closes = 0
    var switches: [UInt64] = []
    _ = try await DesktopPlacementExecution.execute(
      step: step, expected: before, snapshot: { observed },
      open: { opens += 1; return opens > 1 }, close: { closes += 1 },
      activate: { id, display, _ in
        XCTAssertEqual(display, "built-in")
        switches.append(id)
        observed = self.state(builtIn: [1, 2], external: [3], current: id)
      },
      drag: { _, _ in observed = self.state(builtIn: [1], external: [2, 3]) },
      pause: {}, attempts: 1)
    XCTAssertEqual(switches, [1])
    XCTAssertEqual(opens, 2)
    XCTAssertEqual(closes, 0)
  }

  @MainActor
  func testCorrectionAlsoDeactivatesMovedSpaceIfMacOSActivatedItOnArrival() async throws {
    let before = state(builtIn: [1, 2], external: [3])
    var observed = before
    var drags = 0
    var switches: [UInt64] = []
    _ = try await DesktopPlacementExecution.execute(
      step: step, expected: before, snapshot: { observed }, open: { true }, close: {},
      activate: { id, display, _ in
        XCTAssertEqual(display, "external")
        switches.append(id)
        observed = self.state(builtIn: [1], external: [3, 2], externalCurrent: id)
      },
      drag: { _, _ in
        drags += 1
        observed = drags == 1 ? self.state(builtIn: [1], external: [3, 2], externalCurrent: 2)
          : self.state(builtIn: [1], external: [2, 3])
      }, pause: {}, attempts: 1)
    XCTAssertEqual(drags, 2)
    XCTAssertEqual(switches, [3])
  }

  @MainActor
  func testPointerReleasesOnCancellationAndRestoresOurCursor() async {
    var location = CGPoint(x: 5, y: 8)
    var events: [CGEventType] = []
    let pointer = MissionControlPointer(
      location: { location }, leftButtonDown: { false },
      post: { type, point in events.append(type); location = point })
    let operation = Task { @MainActor in
      defer { pointer.restore() }
      try pointer.send(.mouseMoved, to: CGPoint(x: 100, y: 100))
      try pointer.send(.leftMouseDown, to: CGPoint(x: 100, y: 100))
      try pointer.send(.leftMouseDragged, to: CGPoint(x: 200, y: 100))
      withUnsafeCurrentTask { $0?.cancel() }
      try Task.checkCancellation()
    }
    do { _ = try await operation.value; XCTFail("Expected cancellation") } catch {}
    XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved])
    XCTAssertEqual(location, CGPoint(x: 5, y: 8))
  }

  @MainActor
  func testPointerDoesNotReplaceTheUsersNewCursorPosition() throws {
    var location = CGPoint.zero
    var events: [CGEventType] = []
    let pointer = MissionControlPointer(location: { location }, leftButtonDown: { false },
      post: { type, point in events.append(type); location = point })
    try pointer.send(.mouseMoved, to: CGPoint(x: 100, y: 100))
    location = CGPoint(x: 400, y: 400)
    pointer.restore()
    XCTAssertEqual(location, CGPoint(x: 400, y: 400))
    XCTAssertEqual(events, [.mouseMoved])
  }

  @MainActor
  func testPointerDoesNotInterruptAnExistingPhysicalDrag() {
    var posts = 0
    let pointer = MissionControlPointer(location: { .zero }, leftButtonDown: { true }, post: { _, _ in posts += 1 })
    XCTAssertThrowsError(try pointer.send(.mouseMoved, to: CGPoint(x: 100, y: 100)))
    pointer.restore()
    XCTAssertEqual(posts, 0)
  }

  func testHelperDecodesStableUUIDAndCurrentSpace() throws {
    let data = Data("[{\"display\":\"external\",\"current\":2,\"spaces\":[{\"id\":2,\"type\":0,\"uuid\":\"11111111-2222-3333-4444-555555555555\"}]}]".utf8)
    let result = try JSONDecoder().decode([ManagedDisplay].self, from: data)
    XCTAssertEqual(result[0].current, 2)
    XCTAssertEqual(result[0].spaces[0].uuid, uuid)
  }

  func testTileGeometryUsesHostAnchorAndExactInsertionOrdinal() throws {
    let raw = CGRect(x: 200, y: 100, width: 80, height: 60)
    XCTAssertEqual(MissionControlTileGeometry.visibleFrame(raw, centered: true), CGRect(x: 160, y: 70, width: 80, height: 60))
    XCTAssertEqual(MissionControlTileGeometry.visibleFrame(raw, centered: false), raw)
    XCTAssertEqual(try MissionControlTileGeometry.destinationAnchor(sourceIndex: 1, targetIndex: 0, sourceCount: 3, targetCount: 1, sameDisplay: false), .init(index: 0, before: true))
    XCTAssertEqual(try MissionControlTileGeometry.destinationAnchor(sourceIndex: 0, targetIndex: 2, sourceCount: 3, targetCount: 3, sameDisplay: true), .init(index: 2, before: false))
    XCTAssertThrowsError(try MissionControlTileGeometry.destinationAnchor(sourceIndex: 0, targetIndex: 3, sourceCount: 3, targetCount: 3, sameDisplay: true))
    XCTAssertFalse(missionControlReady(displayCount: 1, expectedCount: 2, addButtonCounts: [1]))
    XCTAssertFalse(missionControlReady(displayCount: 2, expectedCount: 2, addButtonCounts: [1, 0]))
    XCTAssertTrue(missionControlReady(displayCount: 2, expectedCount: 2, addButtonCounts: [1, 1]))
  }

  private var step: OrdinaryDesktopReturnStep {
    .init(spaceID: 2, stableUUID: uuid, sourceDisplayID: "built-in", targetDisplayID: "external", targetIndex: 0, slot: 0)
  }

  private func state(builtIn: [UInt64], external: [UInt64], current: UInt64 = 1, externalCurrent: UInt64 = 3) -> DesktopSnapshot {
    func spaces(_ ids: [UInt64]) -> [SpaceSnapshot] {
      ids.map { .init(id: $0, kind: .ordinary, stableUUID: $0 == 2 ? uuid : nil) }
    }
    return DesktopSnapshot(displays: [
      .init(id: "built-in", isBuiltIn: true, frame: .init(x: 0, y: 0, width: 1440, height: 900),
        spaces: spaces(builtIn), currentSpaceID: current),
      .init(id: "external", isBuiltIn: false, frame: .init(x: -1920, y: 0, width: 1920, height: 1080),
        spaces: spaces(external), currentSpaceID: externalCurrent),
    ], windows: [])
  }
}
