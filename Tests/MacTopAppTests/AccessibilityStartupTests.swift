import AppKit
import XCTest
@testable import MacTopApp

final class AccessibilityStartupTests: XCTestCase {
    func testDismissedPromptIsNotRepeatedAndGrantUnlocksTheMenu() async {
        await MainActor.run {
            _ = NSApplication.shared
            var granted = false
            var prompts = 0
            let delegate = AppDelegate(hasAccessibility: { granted }, requestAccessibility: { _ in prompts += 1 })
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

            XCTAssertEqual(prompts, 1)
            let menu = delegate.statusMenu
            for _ in 0..<2 {
                delegate.menuNeedsUpdate(menu)
                XCTAssertEqual(menu.item(withTitle: "Permitir Accesibilidad…")?.isHidden, false)
                XCTAssertEqual(menu.item(withTitle: "Restaurar ahora")?.isEnabled, false)
            }
            granted = true
            delegate.menuNeedsUpdate(menu)
            XCTAssertEqual(menu.item(withTitle: "Permitir Accesibilidad…")?.isHidden, true)
            XCTAssertEqual(prompts, 1)
        }
    }

    func testAlreadyAuthorizedLaunchIsSilent() async {
        await MainActor.run {
            _ = NSApplication.shared
            let delegate = AppDelegate(hasAccessibility: { true }, requestAccessibility: { _ in XCTFail("Unexpected prompt") })
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
            let menu = delegate.statusMenu
            delegate.menuNeedsUpdate(menu)
            XCTAssertEqual(menu.item(withTitle: "Permitir Accesibilidad…")?.isHidden, true)
            XCTAssertNotNil(menu.item(withTitle: "Restaurar ahora"))
        }
    }
}
