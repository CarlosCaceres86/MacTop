import AppKit
import ApplicationServices
import MacTopCore

struct MissionControlDisplayGroup {
  let displayID: UInt32?
  let frame: CGRect?
}

// A missing AXDisplayID is accepted only when every live display has exactly one matching group.
func missionControlDisplayIndex(
  target: UInt32, groups: [MissionControlDisplayGroup], displays: [UInt32: CGRect]
) throws -> Int {
  guard displays[target] != nil else { throw missionControlUnavailable() }
  let exact = groups.indices.filter { groups[$0].displayID == target }
  if exact.count == 1 { return exact[0] }
  guard exact.isEmpty, groups.count == displays.count else { throw missionControlUnavailable() }
  var associated: [UInt32: Int] = [:]
  for (index, group) in groups.enumerated() {
    guard let frame = group.frame else { throw missionControlUnavailable() }
    let matching = displays.filter { _, actual in
      abs(frame.minX - actual.minX) < 0.5 && abs(frame.minY - actual.minY) < 0.5
        && abs(frame.width - actual.width) < 0.5 && abs(frame.height - actual.height) < 0.5
    }.map(\.key)
    guard matching.count == 1, let id = matching.first, associated[id] == nil,
      group.displayID == nil || group.displayID == id else { throw missionControlUnavailable() }
    associated[id] = index
  }
  guard let index = associated[target] else { throw missionControlUnavailable() }
  return index
}

func missionControlUnavailable() -> SystemFailure {
  .unavailable("Could not uniquely identify the display or Mission Control controls.")
}

func missionControlReady(displayCount: Int, expectedCount: Int, addButtonCounts: [Int]) -> Bool {
  displayCount == expectedCount && addButtonCounts.count == expectedCount && addButtonCounts.allSatisfy { $0 == 1 }
}

@MainActor
final class MissionControlAccessibility {
  nonisolated static func hostBundleIDs(majorVersion: Int) -> [String] {
    majorVersion >= 27 ? ["com.apple.WindowManager", "com.apple.dock"]
      : ["com.apple.dock", "com.apple.WindowManager"]
  }

  // Readback and cleanup must finish after an issued action, including on task cancellation.
  static func pause() async {
    await Task.detached { try? await Task.sleep(nanoseconds: 100_000_000) }.value
  }

  func open(displayCount: Int) async throws -> Bool {
    guard AXIsProcessTrusted() else { throw MacTopCoreError.missingPermission }
    if isPresent {
      for _ in 0..<30 {
        if isReady(displayCount: displayCount) { return false }
        await Self.pause()
      }
      throw SystemFailure.unavailable("Mission Control was already open, but its displays are not ready.")
    }
    try Task.checkCancellation()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(
        at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: configuration
      ) { _, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    for _ in 0..<30 {
      if isReady(displayCount: displayCount) { return true }
      await Self.pause()
    }
    // Opening may have completed late; close only the UI that this call requested.
    try? await close()
    throw SystemFailure.unavailable("Mission Control did not show the display groups in time.")
  }

  func requireOpen(displayCount: Int) async throws {
    for _ in 0..<30 {
      guard isPresent else {
        throw SystemFailure.changed("Mission Control closed during recovery. It will not be reopened.")
      }
      if isReady(displayCount: displayCount) { return }
      try Task.checkCancellation()
      await Self.pause()
    }
    throw missionControlUnavailable()
  }

  func close() async throws {
    guard isPresent else { return }
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
      CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
    }
    for _ in 0..<20 {
      if !isPresent { return }
      await Self.pause()
    }
    throw SystemFailure.partial("Could not verify that Mission Control closed.")
  }

  func pressAdd(displayID: String, expected: DesktopSnapshot) throws {
    guard AXIsProcessTrusted() else { throw MacTopCoreError.missingPermission }
    guard let root = root() else { throw missionControlUnavailable() }
    let physical = try physicalDisplays(expected: expected)
    guard let target = physical.first(where: { $0.uuid.caseInsensitiveCompare(displayID) == .orderedSame }) else {
      throw missionControlUnavailable()
    }
    let groups = Self.children(root).filter { Self.identifier($0) == "mc.display" }
    let descriptions = groups.map { group in
      MissionControlDisplayGroup(
        displayID: (Self.attribute(group, "AXDisplayID") as? NSNumber)?.uint32Value,
        frame: Self.frame(group))
    }
    let index = try missionControlDisplayIndex(
      target: target.id, groups: descriptions,
      displays: Dictionary(uniqueKeysWithValues: physical.map { ($0.id, $0.frame) }))
    let buttons = Self.find(groups[index], identifier: "mc.spaces.add", depth: 4)
    guard buttons.count == 1, let button = buttons.first,
      Self.attribute(button, kAXRoleAttribute) as? String == kAXButtonRole else {
      throw missionControlUnavailable()
    }
    try Task.checkCancellation()
    let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard status == .success else {
      throw SystemFailure.partial("Mission Control returned an error when clicking “+” (\(status.rawValue)). The result will be checked without repeating the click.")
    }
  }

  func locatedRoot() -> (element: AXUIElement, centeredTiles: Bool)? {
    for bundle in Self.hostBundleIDs(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
      guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
      let host = AXUIElementCreateApplication(application.processIdentifier)
      AXUIElementSetMessagingTimeout(host, 0.15)
      let roots = bundle == "com.apple.dock"
        ? Self.children(host).filter { Self.identifier($0) == "mc" } : [host]
      if let ready = roots.first(where: { Self.children($0).contains { Self.identifier($0) == "mc.display" } }) {
        return (ready, bundle == "com.apple.WindowManager")
      }
    }
    return nil
  }

  private func root() -> AXUIElement? { locatedRoot()?.element }

  private var isPresent: Bool {
    if root() != nil { return true }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
    let application = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.15)
    return Self.children(application).contains { Self.identifier($0) == "mc" }
  }

  private func isReady(displayCount: Int) -> Bool {
    guard let root = root() else { return false }
    let displays = Self.children(root).filter { Self.identifier($0) == "mc.display" }
    return missionControlReady(
      displayCount: displays.count, expectedCount: displayCount,
      addButtonCounts: displays.map { Self.find($0, identifier: "mc.spaces.add", depth: 4).count })
  }

  func physicalDisplays(expected: DesktopSnapshot) throws -> [(id: UInt32, uuid: String, frame: CGRect)] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count == expected.displays.count,
      count <= 1 || NSScreen.screensHaveSeparateSpaces else { throw missionControlUnavailable() }
    var ids = [UInt32](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success, Int(count) == ids.count else {
      throw missionControlUnavailable()
    }
    return try ids.map { id in
      guard CGDisplayIsInMirrorSet(id) == 0, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
        throw missionControlUnavailable()
      }
      let token = CFUUIDCreateString(nil, uuid)! as String
      let matches = expected.displays.filter { $0.id.caseInsensitiveCompare(token) == .orderedSame }
      guard matches.count == 1, matches[0].frame.rect == CGDisplayBounds(id),
        matches[0].isBuiltIn == (CGDisplayIsBuiltin(id) != 0) else { throw missionControlUnavailable() }
      return (id, token, CGDisplayBounds(id))
    }
  }

  static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }

  static func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }

  static func identifier(_ element: AXUIElement) -> String {
    attribute(element, kAXIdentifierAttribute) as? String ?? ""
  }

  static func find(_ element: AXUIElement, identifier: String, depth: Int) -> [AXUIElement] {
    if Self.identifier(element) == identifier { return [element] }
    guard depth > 0 else { return [] }
    return children(element).flatMap { find($0, identifier: identifier, depth: depth - 1) }
  }

  static func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    let pointValue = position as! AXValue
    let sizeValue = size as! AXValue
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions),
      point.x.isFinite, point.y.isFinite, dimensions.width > 0, dimensions.height > 0,
      dimensions.width.isFinite, dimensions.height.isFinite else { return nil }
    return CGRect(origin: point, size: dimensions)
  }
}
