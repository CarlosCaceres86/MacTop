import AppKit
import XCTest
@testable import MacTopApp

final class RestorationOverlayTests: XCTestCase {
    func testOverlayCoversDisplaysWithoutTakingFocusAndClosesWhenFinished() async throws {
        try await MainActor.run {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("No graphical session is available") }
            _ = NSApplication.shared
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let keyWindow = NSApplication.shared.keyWindow
            let overlay = RestorationOverlayController()
            defer { overlay.hide() }

            overlay.update(phase: .recoveringDesktops, profileName: "MacBook + monitor")
            let panels = overlay.panels
            XCTAssertEqual(panels.count, NSScreen.screens.count)
            XCTAssertEqual(panels.filter(\.showsHUD).count, 1)
            for panel in panels {
                XCTAssertFalse(panel.canBecomeKey)
                XCTAssertFalse(panel.canBecomeMain)
                XCTAssertFalse(panel.isKeyWindow)
                XCTAssertFalse(panel.isMainWindow)
                XCTAssertTrue(panel.isVisible)
                XCTAssertTrue(panel.ignoresMouseEvents)
                XCTAssertEqual(panel.level, .floating)
                XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
                XCTAssertTrue(panel.styleMask.contains(.borderless))
                XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
                XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
                XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
                XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary))
                XCTAssertTrue(NSScreen.screens.contains { $0.frame == panel.frame })
            }
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
            XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)

            overlay.update(phase: .placingWindows, profileName: "MacBook + monitor")
            XCTAssertTrue(zip(panels, overlay.panels).allSatisfy { $0 === $1 })
            overlay.update(phase: .verifying, profileName: "MacBook + monitor")
            overlay.update(phase: nil, profileName: "MacBook + monitor")
            XCTAssertTrue(overlay.panels.isEmpty)
            XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
        }
    }

    func testClosingForScreenChangeReplacesEveryPanelOnNextRestoration() async throws {
        try await MainActor.run {
            guard !NSScreen.screens.isEmpty else { throw XCTSkip("No graphical session is available") }
            let overlay = RestorationOverlayController()
            defer { overlay.hide() }
            overlay.update(phase: .placingWindows, profileName: "MacBook")
            let oldPanels = overlay.panels
            overlay.hide()
            XCTAssertTrue(overlay.panels.isEmpty)
            XCTAssertTrue(oldPanels.allSatisfy { !$0.isVisible })
            overlay.update(phase: .recoveringDesktops, profileName: "MacBook + monitor")
            XCTAssertEqual(overlay.panels.count, NSScreen.screens.count)
            XCTAssertTrue(overlay.panels.allSatisfy { panel in !oldPanels.contains { $0 === panel } })
            XCTAssertTrue(oldPanels.allSatisfy { !$0.isVisible })
            XCTAssertTrue(overlay.panels.allSatisfy { panel in NSScreen.screens.contains { $0.frame == panel.frame } })
        }
    }
}
