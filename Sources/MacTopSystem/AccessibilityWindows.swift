import AppKit
import ApplicationServices
import Darwin
import MacTopCore

private typealias WindowIDFunction =
  @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

struct AccessibleWindow {
  let element: AXUIElement
  let id: UInt32
  let isStandard: Bool?
}

private struct RunningApp: Sendable {
  let pid: Int32
  let launchDate: Date?
  let bundleIdentifier: String?
}

@MainActor
extension MacWindowSystem {
  func inventory(_ raw: [ManagedWindow], hasPermission: Bool, ordinarySpaceIDs: Set<UInt64>) async
    -> [WindowSnapshot]
  {
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isTerminated
    }.map {
      RunningApp(
        pid: $0.processIdentifier, launchDate: $0.launchDate, bundleIdentifier: $0.bundleIdentifier)
    }
    return await Task.detached {
      var result: [WindowSnapshot] = []
      for app in apps {
        let pid = app.pid
        let accessible = hasPermission ? accessibleWindows(pid: pid) : nil
        let applicationIssue =
          app.bundleIdentifier == nil || app.launchDate == nil
          ? String(localized: "Could not verify the application instance.") : nil
        let process = ProcessIdentity(pid: pid, launchDate: app.launchDate ?? .distantPast)
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let windowIDs = Set(raw.filter { $0.pid == pid }.map(\.id))
        for window in raw where window.pid == pid {
          let matches = accessible?.filter { $0.id == window.id } ?? []
          if matches.count == 1 && matches[0].isStandard == false { continue }
          let issue = inventoryIssue(
            applicationIssue: applicationIssue, hasPermission: hasPermission,
            matchedAXKinds: matches.map(\.isStandard), spaceIDs: window.spaces,
            ordinarySpaceIDs: ordinarySpaceIDs,
            frame: WindowFrame(x: window.x, y: window.y, width: window.w, height: window.h))
          result.append(
            WindowSnapshot(
              identity: WindowIdentity(
                process: process, windowID: window.id, bundleIdentifier: bundleIdentifier),
              title: "",
              frame: WindowFrame(x: window.x, y: window.y, width: window.w, height: window.h),
              spaceIDs: window.spaces, verificationIssue: issue))
        }
        // AX may know a minimized window that WindowServer omitted; keep it pending.
        for window in accessible ?? []
        where window.isStandard != false && !windowIDs.contains(window.id) {
          result.append(
            WindowSnapshot(
              identity: WindowIdentity(
                process: process, windowID: window.id, bundleIdentifier: bundleIdentifier),
              title: "", frame: WindowFrame(.zero), spaceIDs: [],
              verificationIssue: applicationIssue
                ?? String(localized: "WindowServer could not verify this window’s desktop membership."))
          )
        }
      }
      return result
    }.value
  }

  func reposition(_ move: WindowMove, window: WindowSnapshot, displays: [DisplaySnapshot]) throws {
    guard let app = NSRunningApplication(processIdentifier: move.identity.process.pid),
      app.launchDate == move.identity.process.launchDate,
      app.bundleIdentifier == move.identity.bundleIdentifier,
      let destination = displays.first(where: { $0.id == move.displayID }),
      let windows = accessibleWindows(pid: move.identity.process.pid)
    else {
      throw SystemFailure.partial(
        String(localized: "Could not verify the same window for placement on the destination display."))
    }
    let matches = windows.filter { $0.id == move.identity.windowID && $0.isStandard == true }
    guard matches.count == 1 else {
      throw SystemFailure.partial(
        String(localized: "The AX identity is not unique; coordinates were not changed."))
    }
    let element = matches[0].element
    let target = destination.frame.rect.insetBy(dx: 24, dy: 48)
    guard target.width > 0, target.height > 0 else {
      throw SystemFailure.partial(String(localized: "The destination geometry is invalid."))
    }
    let width = min(window.frame.width, target.width)
    let height = min(window.frame.height, target.height)
    if width < window.frame.width || height < window.frame.height {
      var size = CGSize(width: width, height: height)
      guard let value = AXValueCreate(.cgSize, &size),
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
      else {
        throw SystemFailure.partial(
          String(localized: "The window reached the desktop, but the application does not allow resizing it to the display."))
      }
    }
    var point = CGPoint(x: target.minX, y: target.minY)
    guard let value = AXValueCreate(.cgPoint, &point),
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    else {
      throw SystemFailure.partial(
        String(localized: "The window reached the desktop, but the application does not allow positioning it physically on the display.")
      )
    }
  }

}

private func accessibleWindows(pid: pid_t) -> [AccessibleWindow]? {
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
    return nil
  }
  let windowID = unsafeBitCast(symbol, to: WindowIDFunction.self)
  let application = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(application, 0.15)
  var value: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
    let windows = value as? [AXUIElement]
  else { return nil }
  return windows.compactMap { element in
    AXUIElementSetMessagingTimeout(element, 0.15)
    var id: CGWindowID = 0
    guard windowID(element, &id) == .success, id > 0 else { return nil }
    let role = stringAttribute(element, kAXRoleAttribute)
    let subrole = stringAttribute(element, kAXSubroleAttribute)
    let standard: Bool? =
      role == nil || subrole == nil
      ? nil : (role == kAXWindowRole && subrole == kAXStandardWindowSubrole)
    return AccessibleWindow(element: element, id: id, isStandard: standard)
  }
}

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
    return nil
  }
  return value as? String
}

// Inactive Spaces can omit AXWindows. WindowServer ownership, normal layer,
// ordinary exclusive Space and geometry still identify those session windows.
func inventoryIssue(
  applicationIssue: String?, hasPermission: Bool, matchedAXKinds: [Bool?],
  spaceIDs: [UInt64], ordinarySpaceIDs: Set<UInt64>, frame: WindowFrame
) -> String? {
  if let applicationIssue { return applicationIssue }
  guard hasPermission else { return String(localized: "Accessibility permission is required to verify the inventory.") }
  guard frame.isValid else { return String(localized: "The window geometry is not verified.") }
  guard matchedAXKinds.count <= 1, matchedAXKinds.first.map({ $0 == true }) ?? true else {
    return String(localized: "The AX identity or ordinary window type is not verified.")
  }
  guard spaceIDs.count == 1, let space = spaceIDs.first, ordinarySpaceIDs.contains(space) else {
    return String(localized: "The window does not belong exclusively to a verified ordinary desktop.")
  }
  return nil
}
