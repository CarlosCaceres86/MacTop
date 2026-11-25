import AppKit
import ApplicationServices
import MacTopCore

// Mission Control geometry and the native grab/detach/drop flow are adapted from Spaceballs; see Vendor/Spaceballs.
enum MissionControlTileGeometry {
  struct Anchor: Equatable { let index: Int; let before: Bool }

  static func visibleFrame(_ frame: CGRect, centered: Bool) -> CGRect {
    centered ? frame.offsetBy(dx: -frame.width / 2, dy: -frame.height / 2) : frame
  }

  static func destinationAnchor(
    sourceIndex: Int, targetIndex: Int, sourceCount: Int, targetCount: Int, sameDisplay: Bool
  ) throws -> Anchor {
    guard sourceIndex >= 0, sourceIndex < sourceCount else { throw missionControlUnavailable() }
    let remaining = (0..<targetCount).filter { !sameDisplay || $0 != sourceIndex }
    guard !remaining.isEmpty, targetIndex >= 0, targetIndex <= remaining.count else { throw missionControlUnavailable() }
    return targetIndex == remaining.count
      ? Anchor(index: remaining.last!, before: false) : Anchor(index: remaining[targetIndex], before: true)
  }

  static func insertionPoint(tile: CGRect, bar: CGRect, before: Bool) -> CGPoint {
    let inset = min(8, tile.width * 0.08)
    return CGPoint(x: before ? tile.minX + inset : tile.maxX - inset, y: bar.midY)
  }
}

@MainActor
final class MissionControlPointer {
  private let location: () -> CGPoint
  private let leftButtonDown: () -> Bool
  private let post: (CGEventType, CGPoint) -> Void
  private let original: CGPoint
  private var last: CGPoint?
  private var pressed = false

  init(
    location: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
    leftButtonDown: @escaping () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) },
    post: @escaping (CGEventType, CGPoint) -> Void = { type, point in
      let source = CGEventSource(stateID: .hidSystemState)
      CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
  ) {
    self.location = location; self.leftButtonDown = leftButtonDown; self.post = post
    original = location()
  }

  func send(_ type: CGEventType, to point: CGPoint) throws {
    try Task.checkCancellation()
    guard point.x.isFinite, point.y.isFinite,
      pressed || !leftButtonDown(),
      type != .leftMouseDown || (!pressed && !leftButtonDown()) else {
      throw SystemFailure.changed(String(localized: "The pointer is already dragging. The desktop was not grabbed."))
    }
    if type == .leftMouseDown { pressed = true }
    if type == .leftMouseUp { pressed = false }
    post(type, point)
    last = point
  }

  func restore() {
    let current = location()
    let ours = last.map { hypot($0.x - current.x, $0.y - current.y) < 2 } ?? false
    if pressed { post(.leftMouseUp, current); pressed = false }
    // Preserve a manual cursor movement made while MacTop was operating.
    if ours { post(.mouseMoved, original) }
    last = nil
  }
}

extension MissionControlAccessibility {
  func activate(spaceID: UInt64, displayID: String, expected: DesktopSnapshot) throws {
    guard AXIsProcessTrusted() else { throw MacTopCoreError.missingPermission }
    guard let tree = locatedRoot(),
      let display = expected.displays.first(where: { $0.id == displayID }),
      let index = display.spaces.firstIndex(where: { $0.id == spaceID && $0.kind == .ordinary }) else {
      throw missionControlUnavailable()
    }
    let bar = try desktopBar(displayID: displayID, expected: expected, root: tree.element)
    try Task.checkCancellation()
    let result = AXUIElementPerformAction(bar.buttons[index], kAXPressAction as CFString)
    guard result == .success else { throw SystemFailure.partial(String(localized: "Mission Control did not confirm activation of the sibling desktop.")) }
  }

  func drag(
    _ step: OrdinaryDesktopReturnStep, expected: DesktopSnapshot,
    beforeGrab: () async throws -> Void
  ) async throws {
    guard AXIsProcessTrusted() else { throw MacTopCoreError.missingPermission }
    guard let tree = locatedRoot(),
      let source = expected.displays.first(where: { $0.id == step.sourceDisplayID }),
      let sourceIndex = source.spaces.firstIndex(where: { $0.id == step.spaceID && $0.kind == .ordinary }),
      step.stableUUID == nil || source.spaces[sourceIndex].stableUUID == step.stableUUID else {
      throw missionControlUnavailable()
    }
    let sourceBar = try desktopBar(displayID: step.sourceDisplayID, expected: expected, root: tree.element)
    let targetBar = try desktopBar(displayID: step.targetDisplayID, expected: expected, root: tree.element)
    let anchor = try MissionControlTileGeometry.destinationAnchor(
      sourceIndex: sourceIndex, targetIndex: step.targetIndex,
      sourceCount: sourceBar.buttons.count, targetCount: targetBar.buttons.count,
      sameDisplay: step.sourceDisplayID == step.targetDisplayID)
    let tile = sourceBar.buttons[sourceIndex]
    let targetTile = targetBar.buttons[anchor.index]
    let pointer = MissionControlPointer()
    defer { pointer.restore() }
    guard let initialBar = Self.frame(sourceBar.list) else { throw missionControlUnavailable() }
    let below = CGPoint(x: initialBar.midX, y: initialBar.maxY + 50)
    try pointer.send(.mouseMoved, to: below)
    for part in 1...8 {
      try pointer.send(.mouseMoved, to: CGPoint(x: below.x, y: below.y + (initialBar.midY - below.y) * Double(part) / 8))
      await dragPause(16_000_000)
    }
    let grab = try await settledTile(tile, bar: sourceBar.list, centered: tree.centeredTiles)
    try await beforeGrab()
    // Re-resolve the physical UUIDs and AX counts immediately before grabbing.
    let freshSource = try desktopBar(displayID: step.sourceDisplayID, expected: expected, root: tree.element)
    let freshTarget = try desktopBar(displayID: step.targetDisplayID, expected: expected, root: tree.element)
    guard CFEqual(freshSource.buttons[sourceIndex], tile), CFEqual(freshTarget.buttons[anchor.index], targetTile),
      let rawGrab = Self.frame(tile), let freshBar = Self.frame(sourceBar.list) else {
      throw SystemFailure.changed(String(localized: "Mission Control rebuilt its thumbnails before the drag."))
    }
    let visibleGrab = MissionControlTileGeometry.visibleFrame(rawGrab, centered: tree.centeredTiles)
    let freshGrab = CGPoint(x: visibleGrab.midX, y: tree.centeredTiles ? visibleGrab.midY : freshBar.midY)
    guard hypot(freshGrab.x - grab.x, freshGrab.y - grab.y) <= 2 else {
      throw SystemFailure.changed(String(localized: "The thumbnail changed position before the drag."))
    }
    try pointer.send(.mouseMoved, to: grab)
    try pointer.send(.leftMouseDown, to: grab)
    await dragPause(80_000_000)
    var point = grab
    for part in 1...3 {
      point = CGPoint(x: grab.x, y: grab.y + Double(part) * 10)
      try pointer.send(.leftMouseDragged, to: point)
      await dragPause(10_000_000)
    }
    func destination() throws -> CGPoint {
      _ = try physicalDisplays(expected: expected)
      guard let rawTile = Self.frame(targetTile), let bar = Self.frame(targetBar.list) else { throw missionControlUnavailable() }
      return MissionControlTileGeometry.insertionPoint(
        tile: MissionControlTileGeometry.visibleFrame(rawTile, centered: tree.centeredTiles),
        bar: bar, before: anchor.before)
    }
    for _ in 0..<100 {
      let target = try destination()
      let distance = hypot(target.x - point.x, target.y - point.y)
      if distance < 2 { break }
      let ratio = min(1, 160 / distance)
      point = CGPoint(x: point.x + (target.x - point.x) * ratio, y: point.y + (target.y - point.y) * ratio)
      try pointer.send(.leftMouseDragged, to: point)
      await dragPause(8_000_000)
    }
    // Ride out expansion and the insertion animation while keeping the native drag alive.
    var previous: CGPoint?
    var settled = 0
    for _ in 0..<40 {
      let target = try destination()
      try pointer.send(.leftMouseDragged, to: target)
      point = target
      let expanded = tileExpanded(targetTile, bar: targetBar.list, centered: tree.centeredTiles)
      if expanded, let previous, hypot(previous.x - target.x, previous.y - target.y) <= 2 { settled += 1 }
      else { settled = 0 }
      if settled >= 7 { break }
      previous = target
      await dragPause(50_000_000)
    }
    guard settled >= 7 else { throw SystemFailure.partial(String(localized: "The destination bar did not stabilize during the drag. The desktop location will be checked.")) }
    try pointer.send(.leftMouseUp, to: point)
    await dragPause(200_000_000)
  }

  private func desktopBar(
    displayID: String, expected: DesktopSnapshot, root: AXUIElement
  ) throws -> (list: AXUIElement, buttons: [AXUIElement]) {
    let physical = try physicalDisplays(expected: expected)
    guard let target = physical.first(where: { $0.uuid.caseInsensitiveCompare(displayID) == .orderedSame }),
      let display = expected.displays.first(where: { $0.id == displayID }),
      display.spaces.allSatisfy({ $0.kind == .ordinary }) else { throw missionControlUnavailable() }
    let groups = Self.children(root).filter { Self.identifier($0) == "mc.display" }
    let index = try missionControlDisplayIndex(
      target: target.id,
      groups: groups.map { .init(displayID: (Self.attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value, frame: Self.frame($0)) },
      displays: Dictionary(uniqueKeysWithValues: physical.map { ($0.id, $0.frame) }))
    let lists = Self.find(groups[index], identifier: "mc.spaces.list", depth: 4)
    guard lists.count == 1, let list = lists.first else { throw missionControlUnavailable() }
    let buttons = Self.children(list).filter { Self.attribute($0, kAXRoleAttribute) as? String == kAXButtonRole }
    guard buttons.count == display.spaces.count else {
      throw SystemFailure.changed(String(localized: "The number of Mission Control thumbnails does not match the inventory. None will be dragged."))
    }
    return (list, buttons)
  }

  private func settledTile(_ tile: AXUIElement, bar: AXUIElement, centered: Bool) async throws -> CGPoint {
    var previous: CGPoint?
    for _ in 0..<40 {
      try Task.checkCancellation()
      if let raw = Self.frame(tile), let barFrame = Self.frame(bar), tileExpanded(tile, bar: bar, centered: centered) {
        let visible = MissionControlTileGeometry.visibleFrame(raw, centered: centered)
        let point = CGPoint(x: visible.midX, y: centered ? visible.midY : barFrame.midY)
        if let previous, hypot(previous.x - point.x, previous.y - point.y) <= 2 { return point }
        previous = point
      } else { previous = nil }
      await dragPause(40_000_000)
    }
    throw SystemFailure.unavailable(String(localized: "The source thumbnail did not expand and stabilize. The desktop was not grabbed."))
  }

  private func tileExpanded(_ tile: AXUIElement, bar: AXUIElement, centered: Bool) -> Bool {
    guard let tileFrame = Self.frame(tile), let barFrame = Self.frame(bar), tileFrame.height >= 40 else { return false }
    return !centered || barFrame.height + 1 >= tileFrame.height
  }

  private func dragPause(_ nanoseconds: UInt64) async {
    await Task.detached { try? await Task.sleep(nanoseconds: nanoseconds) }.value
  }
}
