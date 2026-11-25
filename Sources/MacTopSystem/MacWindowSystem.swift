import AppKit
import ApplicationServices
import Darwin
import MacTopCore

struct ManagedDisplay: Decodable, Equatable {
  struct Space: Decodable, Equatable {
    let id: UInt64
    let type: Int
    let uuid: UUID?
  }
  let display: String
  let current: UInt64?
  let spaces: [Space]
}

struct ManagedWindow: Decodable, Sendable {
  let id: UInt32
  let pid: Int32
  let spaces: [UInt64]
  let x: Double
  let y: Double
  let w: Double
  let h: Double
}

@MainActor
public final class MacWindowSystem {
  private let helperURL: URL?
  private var moving = false

  public init() { helperURL = Bundle.main.url(forAuxiliaryExecutable: "spacectl") }
  init(helperURL: URL) { self.helperURL = helperURL }

  public func requestAccessibilityPermission() {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  public func snapshot() async throws -> DesktopSnapshot {
    try await snapshot(scope: .desktop)
  }

  public func displaySnapshot() async throws -> DesktopSnapshot {
    try await snapshot(scope: .displays)
  }

  package func physicalDisplaysMatch(_ expected: DesktopSnapshot) -> Bool {
    (try? MissionControlAccessibility().physicalDisplays(expected: expected)) != nil
  }

  enum SnapshotScope { case desktop, displays }

  private func snapshot(scope: SnapshotScope) async throws -> DesktopSnapshot {
    try await Self.readSnapshot(
      scope: scope, managedDisplays: managedDisplays, physicalDisplays: physicalDisplays,
      hasPermission: AXIsProcessTrusted,
      inventory: { displays in
        let windows: [ManagedWindow] = try await self.read(["windows"])
        let hasPermission = AXIsProcessTrusted()
        let ordinaryIDs = Set(displays.flatMap(\.spaces).filter { $0.kind == .ordinary }.map(\.id))
        return (await self.inventory(windows, hasPermission: hasPermission, ordinarySpaceIDs: ordinaryIDs), hasPermission)
      })
  }

  static func readSnapshot(
    scope: SnapshotScope,
    managedDisplays: () async throws -> [ManagedDisplay],
    physicalDisplays: ([ManagedDisplay]) throws -> [DisplaySnapshot],
    hasPermission: () -> Bool,
    inventory: ([DisplaySnapshot]) async throws -> (windows: [WindowSnapshot], hasPermission: Bool)
  ) async throws -> DesktopSnapshot {
    for _ in 0..<3 {
      let before = try await managedDisplays()
      let displays = try physicalDisplays(before)
      let observed = scope == .desktop ? try await inventory(displays) : (windows: [], hasPermission: hasPermission())
      let after = try await managedDisplays()
      let finalDisplays = try physicalDisplays(after)
      if before == after && displays == finalDisplays {
        let issues = displays.flatMap { display in
          display.spaces.contains(where: { $0.kind == .unknown })
            ? ["Display \(display.id) has a Space of an unverified type."] : []
        }
        return DesktopSnapshot(
          displays: displays, windows: observed.windows,
          hasAccessibilityPermission: observed.hasPermission, isComplete: true, issues: issues,
          includesWindowInventory: scope == .desktop)
      }
    }
    throw SystemFailure.changed(
      "Displays or desktops are changing. Try again when they are stable.")
  }

  public func move(_ move: WindowMove, expectedTopology: DesktopSnapshot) async throws {
    guard !moving else { throw SystemFailure.unavailable("A move is already in progress.") }
    moving = true
    defer { moving = false }
    guard let helperURL else { throw missingHelper() }
    try await WindowMoveExecution.execute(
      move: move, expected: expectedTopology, snapshot: snapshot,
      validate: { try self.validate(move, in: $0, expected: $1) },
      moveSpace: {
        try await HelperProcess.run(
          url: helperURL,
          arguments: [
            "move", String(move.identity.windowID),
            String(move.spaceID), "1500", String(move.identity.process.pid),
            String(move.identity.process.launchDate.timeIntervalSince1970),
          ])
      }, reposition: { try self.reposition(move, window: $0, displays: $1.displays) })
  }

  package func makeDesktopRecoverySession() -> DesktopRecoverySession {
    let missionControl = MissionControlAccessibility()
    return DesktopRecoverySession(
      snapshot: displaySnapshot,
      open: { try await missionControl.open(displayCount: $0) },
      requireOpen: { try await missionControl.requireOpen(displayCount: $0) },
      close: missionControl.close,
      press: { try missionControl.pressAdd(displayID: $0, expected: $1) },
      activate: { try missionControl.activate(spaceID: $0, displayID: $1, expected: $2) },
      drag: { request, reference in
        try await self.dragOrdinaryDesktop(request, reference: reference, missionControl: missionControl, observe: self.displaySnapshot)
      },
      begin: {
        guard !self.moving else { throw SystemFailure.unavailable("A restoration is already in progress.") }
        self.moving = true
      }, end: { self.moving = false })
  }

  public func addOrdinaryDesktop(displayID: String, expected: DesktopSnapshot) async throws -> DesktopSnapshot {
    try await addOrdinaryDesktop(displayID: displayID, expected: expected, includeWindows: true)
  }

  public func addOrdinaryDesktop(displayID: String, expected: DesktopSnapshot, includeWindows: Bool) async throws -> DesktopSnapshot {
    guard !moving else { throw SystemFailure.unavailable("A restoration is already in progress.") }
    moving = true
    defer { moving = false }
    let missionControl = MissionControlAccessibility()
    let observe = includeWindows ? snapshot : displaySnapshot
    return try await DesktopAdditionExecution.execute(
      displayID: displayID, expected: expected, snapshot: observe,
      open: { try await missionControl.open(displayCount: expected.displays.count) }, close: missionControl.close,
      press: { try missionControl.pressAdd(displayID: displayID, expected: expected) })
  }

  public func placeOrdinaryDesktop(_ step: OrdinaryDesktopReturnStep, expected: DesktopSnapshot) async throws -> DesktopSnapshot {
    try await placeOrdinaryDesktop(step, expected: expected, includeWindows: true)
  }

  public func placeOrdinaryDesktop(_ step: OrdinaryDesktopReturnStep, expected: DesktopSnapshot, includeWindows: Bool) async throws -> DesktopSnapshot {
    guard !moving else { throw SystemFailure.unavailable("A restoration is already in progress.") }
    moving = true
    defer { moving = false }
    let missionControl = MissionControlAccessibility()
    let observe = includeWindows ? snapshot : displaySnapshot
    return try await DesktopPlacementExecution.execute(
      step: step, expected: expected, snapshot: observe,
      open: { try await missionControl.open(displayCount: expected.displays.count) },
      close: missionControl.close,
      activate: { try missionControl.activate(spaceID: $0, displayID: $1, expected: $2) },
      drag: { request, reference in
        try await self.dragOrdinaryDesktop(request, reference: reference, missionControl: missionControl, observe: observe)
      })
  }

  private func dragOrdinaryDesktop(
    _ request: OrdinaryDesktopReturnStep, reference: DesktopSnapshot,
    missionControl: MissionControlAccessibility, observe: () async throws -> DesktopSnapshot
  ) async throws {
    try await missionControl.drag(request, expected: reference) {
      let current = try await observe()
      try DesktopPlacementExecution.requireUnchanged(reference, current: current, step: request)
      guard let active = reference.displays.first(where: { $0.id == request.sourceDisplayID })?.currentSpaceID,
        active != request.spaceID,
        current.displays.first(where: { $0.id == request.sourceDisplayID })?.currentSpaceID == active else {
        throw SystemFailure.changed("The active desktop changed before the thumbnail was grabbed.")
      }
    }
  }

  private func read<T: Decodable>(_ arguments: [String]) async throws -> T {
    guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      throw missingHelper()
    }
    let reply = try await HelperProcess.run(url: helperURL, arguments: arguments)
    guard !reply.timedOut, reply.status == 0 else {
      throw SystemFailure.unavailable(
        "Could not read Spaces on this version of macOS. The component failed or timed out."
      )
    }
    return try JSONDecoder().decode(T.self, from: reply.data)
  }

  private func managedDisplays() async throws -> [ManagedDisplay] { try await read(["spaces"]) }

  private func missingHelper() -> SystemFailure {
    .unavailable("The spacectl component is missing. Run the app built with scripts/build-app.sh.")
  }

  private func physicalDisplays(managed: [ManagedDisplay]) throws -> [DisplaySnapshot] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
      throw SystemFailure.unavailable("Could not read the active displays.")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
      throw SystemFailure.unavailable("The list of active displays changed.")
    }
    if count > 1 && !NSScreen.screensHaveSeparateSpaces {
      throw SystemFailure.unavailable(
        "MacTop needs “Displays have separate Spaces” to identify the desktops on each display."
      )
    }
    let screens = NSScreen.screens
    return try ids.prefix(Int(count)).map { id in
      guard CGDisplayIsInMirrorSet(id) == 0,
        let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
      else {
        throw SystemFailure.unavailable(
          "The mirroring configuration or a display identity is not verified.")
      }
      let identifier = CFUUIDCreateString(nil, uuid)! as String
      let matches = managed.filter {
        $0.display.caseInsensitiveCompare(identifier) == .orderedSame
          || ($0.display == "Main" && count == 1)
      }
      guard matches.count == 1 else {
        throw SystemFailure.changed(
          "Cannot associate each list of Spaces with a physical display.")
      }
      let spaces = matches[0].spaces.map { space in
        SpaceSnapshot(
          id: space.id,
          kind: space.type == 0 ? .ordinary : (space.type == 4 ? .fullScreen : .unknown),
          stableUUID: space.uuid)
      }
      let name = screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
      }?.localizedName
      return DisplaySnapshot(
        id: identifier, isBuiltIn: CGDisplayIsBuiltin(id) != 0,
        frame: WindowFrame(CGDisplayBounds(id)), spaces: spaces, currentSpaceID: matches[0].current,
        localizedName: name)
    }.sorted { $0.id < $1.id }
  }

  private func sameTopology(_ first: DesktopSnapshot, _ second: DesktopSnapshot) -> Bool {
    first.isComplete && second.isComplete
      && first.hasSameDisplayStructure(as: second)
  }

  private func validate(_ move: WindowMove, in current: DesktopSnapshot, expected: DesktopSnapshot)
    throws
  {
    guard current.hasAccessibilityPermission else {
      throw SystemFailure.unavailable("Grant MacTop Accessibility permission before restoring windows.")
    }
    guard sameTopology(current, expected),
      let display = current.displays.first(where: { $0.id == move.displayID }),
      display.spaces.contains(where: { $0.id == move.spaceID && $0.kind == .ordinary })
    else {
      throw SystemFailure.changed(
        "The destination display or desktop changed. The restoration must be recalculated.")
    }
    let candidates = current.windows.filter { $0.identity == move.identity }
    guard candidates.count == 1, let window = candidates.first, window.verificationIssue == nil,
      window.spaceIDs.count == 1,
      current.displays.flatMap(\.spaces).contains(where: {
        $0.id == window.spaceIDs[0] && $0.kind == .ordinary
      }),
      let app = NSRunningApplication(processIdentifier: move.identity.process.pid),
      app.launchDate == move.identity.process.launchDate,
      app.bundleIdentifier == move.identity.bundleIdentifier
    else {
      throw SystemFailure.changed(
        "The window identity or mode is no longer verified. It was not moved.")
    }
  }
}

extension WindowFrame {
  init(_ frame: CGRect) {
    self.init(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
  }
  var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

func physicalDisplay(for frame: WindowFrame, in displays: [DisplaySnapshot]) -> String? {
  guard frame.isValid else { return nil }
  let matches = displays.filter { $0.frame.containsCenter(of: frame) }
  return matches.count == 1 ? matches[0].id : nil
}
