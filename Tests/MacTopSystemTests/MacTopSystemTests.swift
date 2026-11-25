import MacTopCore
import XCTest

@testable import MacTopSystem

final class MacTopSystemTests: XCTestCase {
  private let displays = [
    DisplaySnapshot(
      id: "built-in", isBuiltIn: true, frame: WindowFrame(x: 0, y: 0, width: 1440, height: 900),
      spaces: [.init(id: 1, kind: .ordinary)]),
    DisplaySnapshot(
      id: "external", isBuiltIn: false,
      frame: WindowFrame(x: -1920, y: -100, width: 1920, height: 1080),
      spaces: [.init(id: 2, kind: .ordinary)]),
  ]

  func testPhysicalDisplayUsesGlobalCoordinatesAndCenter() {
    XCTAssertEqual(
      physicalDisplay(for: .init(x: -1800, y: 40, width: 900, height: 600), in: displays),
      "external")
    XCTAssertEqual(
      physicalDisplay(for: .init(x: -100, y: 40, width: 900, height: 600), in: displays), "built-in"
    )
    XCTAssertNil(
      physicalDisplay(for: .init(x: 4000, y: 4000, width: 300, height: 300), in: displays))
  }

  func testDisplayBoundaryIsHalfOpen() {
    XCTAssertEqual(
      physicalDisplay(for: .init(x: -300, y: 40, width: 600, height: 400), in: displays), "built-in"
    )
    XCTAssertNil(
      physicalDisplay(
        for: .init(x: -1800, y: 40, width: 900, height: 600), in: displays + [displays[1]]))
  }

  func testHelperDecodingRetainsSpaceOrderAndUnknownTypes() throws {
    let data = Data(
      "[{\"display\":\"external\",\"current\":11,\"spaces\":[{\"id\":11,\"type\":0},{\"id\":2,\"type\":99}]}]"
        .utf8)
    let decoded = try JSONDecoder().decode([ManagedDisplay].self, from: data)
    XCTAssertEqual(decoded[0].spaces.map(\.id), [11, 2])
    XCTAssertEqual(decoded[0].spaces[1].type, 99)
  }

  func testHelperDecodingKeepsSmallAndUnknownMembershipWindows() throws {
    let data = Data(
      "[{\"id\":19,\"pid\":7,\"spaces\":[],\"x\":-50,\"y\":0,\"w\":30,\"h\":25}]".utf8)
    let decoded = try JSONDecoder().decode([ManagedWindow].self, from: data)
    XCTAssertEqual(decoded.count, 1)
    XCTAssertTrue(decoded[0].spaces.isEmpty)
    XCTAssertEqual(decoded[0].x, -50)
  }

  @MainActor
  func testDisplaySnapshotSkipsWindowInventoryAndRetainsDisplayAndPermissionChecks() async throws {
    var events: [String] = []
    let result = try await MacWindowSystem.readSnapshot(
      scope: .displays,
      managedDisplays: { events.append("spaces"); return [self.managedDisplay()] },
      physicalDisplays: { _ in events.append("physical"); return self.displays },
      hasPermission: { events.append("permission"); return false },
      inventory: { _ in
        XCTFail("Display observations must not read windows or their AX inventory")
        return ([], true)
      })
    XCTAssertEqual(events, ["spaces", "physical", "permission", "spaces", "physical"])
    XCTAssertEqual(result.displays, displays)
    XCTAssertTrue(result.windows.isEmpty)
    XCTAssertFalse(result.hasAccessibilityPermission)
    XCTAssertTrue(result.isComplete)
  }

  @MainActor
  func testFullSnapshotStillReadsWindowInventoryBetweenDisplayChecks() async throws {
    var events: [String] = []
    let expected = state(space: 1, external: false)
    let result = try await MacWindowSystem.readSnapshot(
      scope: .desktop,
      managedDisplays: { events.append("spaces"); return [self.managedDisplay()] },
      physicalDisplays: { _ in events.append("physical"); return self.displays },
      hasPermission: { XCTFail("Full inventory owns the permission reading"); return false },
      inventory: { observedDisplays in
        events.append("windows+AX")
        XCTAssertEqual(observedDisplays, self.displays)
        return (expected.windows, true)
      })
    XCTAssertEqual(events, ["spaces", "physical", "windows+AX", "spaces", "physical"])
    XCTAssertEqual(result, expected)
  }

  @MainActor
  func testDisplaySnapshotRetriesIfActiveSpaceOrPhysicalMeasurementsChange() async throws {
    for changesManagedState in [true, false] {
      var managedReads = 0
      var physicalReads = 0
      let result = try await MacWindowSystem.readSnapshot(
        scope: .displays,
        managedDisplays: {
          managedReads += 1
          return [self.managedDisplay(current: changesManagedState && managedReads == 1 ? 2 : 1)]
        },
        physicalDisplays: { _ in
          physicalReads += 1
          if !changesManagedState && physicalReads == 1 { return [self.displays[0]] }
          return self.displays
        },
        hasPermission: { true },
        inventory: { _ in XCTFail("Unexpected window inventory"); return ([], true) })
      XCTAssertEqual(result.displays, displays)
      XCTAssertEqual(managedReads, 4)
      XCTAssertEqual(physicalReads, 4)
    }
  }

  @MainActor
  func testDisplaySnapshotStopsAfterThreeInconsistentObservations() async {
    var reads = 0
    do {
      _ = try await MacWindowSystem.readSnapshot(
        scope: .displays,
        managedDisplays: {
          reads += 1
          return [self.managedDisplay(current: UInt64(reads))]
        },
        physicalDisplays: { _ in self.displays }, hasPermission: { true },
        inventory: { _ in XCTFail("Unexpected window inventory"); return ([], true) })
      XCTFail("Unstable displays must not be accepted")
    } catch {}
    XCTAssertEqual(reads, 6)
  }

  private func managedDisplay(current: UInt64 = 1) -> ManagedDisplay {
    ManagedDisplay(display: "built-in", current: current, spaces: [
      .init(id: 1, type: 0, uuid: nil), .init(id: 2, type: 0, uuid: nil)
    ])
  }

  func testInactiveSpaceWindowServerEvidenceWorksWithoutAXEntry() {
    let frame = WindowFrame(x: 20, y: 20, width: 400, height: 300)
    XCTAssertNil(
      inventoryIssue(
        applicationIssue: nil, hasPermission: true, matchedAXKinds: [],
        spaceIDs: [3], ordinarySpaceIDs: [1, 2, 3], frame: frame))
    XCTAssertNotNil(
      inventoryIssue(
        applicationIssue: nil, hasPermission: true, matchedAXKinds: [],
        spaceIDs: [1, 3], ordinarySpaceIDs: [1, 2, 3], frame: frame))
    XCTAssertNotNil(
      inventoryIssue(
        applicationIssue: "No start date", hasPermission: true, matchedAXKinds: [],
        spaceIDs: [3], ordinarySpaceIDs: [1, 2, 3], frame: frame))
    XCTAssertNotNil(
      inventoryIssue(
        applicationIssue: nil, hasPermission: true, matchedAXKinds: [nil],
        spaceIDs: [3], ordinarySpaceIDs: [1, 2, 3], frame: frame))
    XCTAssertNotNil(
      inventoryIssue(
        applicationIssue: nil, hasPermission: true, matchedAXKinds: [],
        spaceIDs: [99], ordinarySpaceIDs: [1, 2, 3], frame: frame))
  }

  @MainActor
  func testCrossDisplayFailureRepositionsThenRetriesAndObserves() async throws {
    var events: [String] = []
    var states = [
      state(space: 1, external: false), state(space: 1, external: false),
      state(space: 1, external: true), state(space: 2, external: true),
    ]
    let move = WindowMove(identity: identity, displayID: "external", spaceID: 2)
    try await WindowMoveExecution.execute(
      move: move, expected: states[0],
      snapshot: {
        events.append("read")
        return states.removeFirst()
      },
      validate: { current, expected in
        XCTAssertEqual(current.displays, expected.displays)
      },
      moveSpace: {
        events.append("move")
        return HelperReply(data: Data(), status: 1, timedOut: false)
      },
      reposition: { window, _ in
        XCTAssertEqual(window.identity, self.identity)
        events.append("AX")
      })
    XCTAssertEqual(events, ["read", "move", "read", "AX", "read", "move", "read"])
    XCTAssertTrue(states.isEmpty)
  }

  @MainActor
  func testSpaceAssignmentRepairsPhysicalScreenWithoutSecondSpaceMove() async throws {
    var events: [String] = []
    var states = [
      state(space: 1, external: false), state(space: 2, external: false),
      state(space: 2, external: true),
    ]
    try await WindowMoveExecution.execute(
      move: WindowMove(identity: identity, displayID: "external", spaceID: 2),
      expected: states[0],
      snapshot: {
        events.append("read")
        return states.removeFirst()
      },
      validate: { _, _ in },
      moveSpace: {
        events.append("move")
        return HelperReply(data: Data(), status: 0, timedOut: false)
      }, reposition: { _, _ in events.append("AX") })
    XCTAssertEqual(events, ["read", "move", "read", "AX", "read"])
  }

  @MainActor
  func testFailedAXRepairStopsBeforeAnotherMove() async {
    var events: [String] = []
    let initial = state(space: 1, external: false)
    do {
      try await WindowMoveExecution.execute(
        move: WindowMove(identity: identity, displayID: "external", spaceID: 2),
        expected: initial,
        snapshot: {
          events.append("read")
          return initial
        }, validate: { _, _ in },
        moveSpace: {
          events.append("move")
          return HelperReply(data: Data(), status: 1, timedOut: false)
        },
        reposition: { _, _ in
          events.append("AX")
          throw SystemFailure.partial("AX unavailable")
        })
      XCTFail("The failed repair must stay partial")
    } catch {}
    XCTAssertEqual(events, ["read", "move", "read", "AX"])
  }

  @MainActor
  func testCancellationObservesIssuedMoveAndSkipsRepair() async {
    var events: [String] = []
    let initial = state(space: 1, external: false)
    let move = WindowMove(identity: identity, displayID: "external", spaceID: 2)
    let operation = Task { @MainActor in
      try await WindowMoveExecution.execute(
        move: move, expected: initial,
        snapshot: {
          events.append("read")
          return initial
        }, validate: { _, _ in },
        moveSpace: {
          events.append("move")
          withUnsafeCurrentTask { $0?.cancel() }
          return HelperReply(data: Data(), status: 1, timedOut: false)
        }, reposition: { _, _ in events.append("AX") })
    }
    do {
      try await operation.value
      XCTFail("Expected cancellation before repair")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(events, ["read", "move", "read"])
  }

  @MainActor
  func testTopologyRaceStopsBeforeAXRepairOrRetry() async {
    var events: [String] = []
    let initial = state(space: 1, external: false)
    var reads = 0
    do {
      try await WindowMoveExecution.execute(
        move: WindowMove(identity: identity, displayID: "external", spaceID: 2),
        expected: initial,
        snapshot: {
          events.append("read")
          reads += 1
          return initial
        },
        validate: { _, _ in if reads > 1 { throw SystemFailure.changed("Monitor desconectado") } },
        moveSpace: {
          events.append("move")
          return HelperReply(data: Data(), status: 1, timedOut: false)
        },
        reposition: { _, _ in events.append("AX") })
      XCTFail("Expected changed topology to stop recovery")
    } catch {}
    XCTAssertEqual(events, ["read", "move", "read"])
  }

  private var identity: WindowIdentity {
    .init(
      process: .init(pid: 4, launchDate: Date(timeIntervalSince1970: 100)), windowID: 25,
      bundleIdentifier: "test.app")
  }

  private func state(space: UInt64, external: Bool) -> DesktopSnapshot {
    DesktopSnapshot(
      displays: displays,
      windows: [
        .init(
          identity: identity, title: "",
          frame: .init(x: external ? -1800 : 20, y: 40, width: 400, height: 300), spaceIDs: [space])
      ])
  }
}
