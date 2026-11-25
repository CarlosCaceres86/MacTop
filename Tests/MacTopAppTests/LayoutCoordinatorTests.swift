import AppKit
import XCTest
import MacTopCore
@testable import MacTopApp

@MainActor
final class LayoutCoordinatorTests: XCTestCase {
    func testAutomaticReconnectDoesNotWaitForWindowPresentOnMultipleDesktops() async throws {
        let rig = Rig()
        let external = Rig.originalDesktops()
        let window = external.windows[0]
        rig.saved = [try LayoutProfile.capture(snapshot: external)]
        rig.current = DesktopSnapshot(displays: external.displays, windows: [
            WindowSnapshot(identity: window.identity, title: window.title, frame: window.frame, spaceIDs: [10, 11])
        ] + external.windows.dropFirst())
        let coordinator = rig.coordinator(automatic: true)
        var planningPauseCount: Int?
        rig.onFullRead = { if planningPauseCount == nil { planningPauseCount = rig.pauseCount } }

        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(try XCTUnwrap(planningPauseCount), rig.pauseCount)
        XCTAssertEqual(rig.fullReadCount, 2)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(coordinator.status.hasPrefix("Partial restoration"))
    }

    func testAutomaticReconnectReturnsAllOriginalDesktopsDespiteScreenNotificationDuringFirstReturn() async throws {
        let rig = Rig()
        let external = Rig.originalDesktops()
        let migrated = Rig.originalDesktops(migrated: true)
        let portable = DesktopSnapshot(displays: [migrated.displays[0]], windows: migrated.windows)
        rig.current = external
        rig.saved = [try LayoutProfile.capture(snapshot: external), try LayoutProfile.capture(snapshot: portable)]
        let profiles = rig.saved
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        rig.current = portable
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()

        rig.current = migrated
        rig.onPlace = {
            if rig.placements.count == 1 {
                coordinator.receive(.screensChanged)
                coordinator.receive(.screensChanged)
            }
        }
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(rig.placements.map(\.spaceID), [10, 11, 12])
        XCTAssertEqual(rig.sessionCount, 1)
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertTrue(rig.additions.isEmpty)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertEqual(Array(rig.current.displays[1].spaces.prefix(3)).map(\.id), [10, 11, 12])
        XCTAssertTrue(RestorationPlanner.plan(profile: profiles[0], snapshot: rig.current).isComplete)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        XCTAssertEqual(rig.saved, profiles)
    }

    func testAutomaticReconnectCancelsReturnWhenPhysicalDisplaysCannotBeConfirmed() async throws {
        for change in ["frame", "monitor", "unavailable"] {
            let rig = Rig()
            let external = Rig.originalDesktops()
            let migrated = Rig.originalDesktops(migrated: true)
            rig.current = external
            rig.saved = [try LayoutProfile.capture(snapshot: external)]
            let profiles = rig.saved
            let coordinator = rig.coordinator(automatic: true)
            coordinator.start()
            await coordinator.waitUntilIdle()
            rig.current = DesktopSnapshot(displays: [migrated.displays[0]], windows: migrated.windows)
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            rig.current = migrated
            rig.onPlace = {
                if change == "unavailable" {
                    rig.canConfirmPhysicalDisplays = false
                } else {
                    rig.current = DesktopSnapshot(displays: rig.current.displays.map { display in
                        guard !display.isBuiltIn else { return display }
                        return DisplaySnapshot(id: change == "monitor" ? "another-monitor" : display.id,
                            isBuiltIn: display.isBuiltIn,
                            frame: .init(x: change == "frame" ? 2000 : display.frame.x,
                                y: display.frame.y, width: display.frame.width, height: display.frame.height),
                            spaces: display.spaces)
                    }, windows: rig.current.windows)
                }
                coordinator.receive(.screensChanged)
            }
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()

            XCTAssertEqual(rig.placements.map(\.spaceID), [10], change)
            XCTAssertEqual(rig.sessionCount, 1, change)
            XCTAssertEqual(rig.finishCount, 1, change)
            XCTAssertTrue(rig.additions.isEmpty, change)
            XCTAssertTrue(rig.moves.isEmpty, change)
            XCTAssertEqual(rig.saved, profiles, change)
            XCTAssertFalse(coordinator.status.hasPrefix("Restored"), change)
        }
    }

    func testAutomaticReconnectPlacesWindowFirstSeenInFinalOrFollowingInventoryWithoutRepeatingDesktopReturns() async throws {
        for appearanceRead in [nil, 1, 2, 3] as [Int?] {
            let rig = Rig()
            let external = Rig.originalDesktops()
            let migrated = Rig.originalDesktops(migrated: true)
            let missing = try XCTUnwrap(external.windows.last)
            let portable = DesktopSnapshot(displays: [migrated.displays[0]], windows: migrated.windows)
            rig.current = external
            rig.saved = [try LayoutProfile.capture(snapshot: external), try LayoutProfile.capture(snapshot: portable)]
            let profiles = rig.saved
            let coordinator = rig.coordinator(automatic: true)
            coordinator.start()
            await coordinator.waitUntilIdle()
            rig.current = portable
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()

            rig.current = DesktopSnapshot(displays: migrated.displays,
                windows: migrated.windows.filter { $0.identity != missing.identity })
            let planningRead = rig.fullReadCount + 1
            var planningPauseCount = 0
            rig.onFullRead = {
                if rig.fullReadCount == planningRead { planningPauseCount = rig.pauseCount }
                guard let appearanceRead, rig.fullReadCount == planningRead + appearanceRead - 1 else { return }
                XCTAssertEqual(rig.placements.map(\.spaceID), [10, 11, 12])
                XCTAssertEqual(rig.finishCount, 1)
                rig.current = DesktopSnapshot(displays: rig.current.displays, windows: rig.current.windows + [
                    WindowSnapshot(identity: missing.identity, title: missing.title,
                        frame: .init(x: 20, y: 20, width: 100, height: 100), spaceIDs: [1])
                ])
            }
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()

            XCTAssertEqual(rig.placements.map(\.spaceID), [10, 11, 12])
            XCTAssertEqual(rig.sessionCount, 1)
            XCTAssertEqual(rig.finishCount, 1)
            XCTAssertTrue(rig.additions.isEmpty)
            XCTAssertEqual(rig.moves.map(\.identity), appearanceRead != nil ? [missing.identity] : [])
            XCTAssertEqual(rig.saved, profiles)
            XCTAssertLessThanOrEqual(rig.pauseCount - planningPauseCount, 2)
            if appearanceRead != nil {
                XCTAssertEqual(rig.moves.first?.spaceID, 12)
                XCTAssertEqual(rig.moves.first?.displayID, "monitor")
                XCTAssertTrue(RestorationPlanner.plan(profile: profiles[0], snapshot: rig.current).isComplete)
                XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
            } else {
                XCTAssertFalse(rig.current.windows.contains { $0.identity == missing.identity })
                XCTAssertTrue(coordinator.status.hasPrefix("Partial restoration"))
            }
        }
    }

    func testAutomaticReconnectDoesNotRetryUnverifiedMoveWhenAnotherWindowAppearsInFinalInventory() async throws {
        let rig = Rig()
        let external = Rig.originalDesktops()
        let migrated = Rig.originalDesktops(migrated: true)
        let attempted = external.windows[0]
        let missing = external.windows[2]
        rig.current = external
        rig.saved = [try LayoutProfile.capture(snapshot: external)]
        let profiles = rig.saved
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        rig.current = DesktopSnapshot(displays: [migrated.displays[0]], windows: migrated.windows)
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        rig.current = DesktopSnapshot(displays: migrated.displays, windows: migrated.windows.compactMap { window in
            if window.identity == missing.identity { return nil }
            guard window.identity == attempted.identity else { return window }
            return WindowSnapshot(identity: window.identity, title: window.title,
                frame: .init(x: 20, y: 20, width: 100, height: 100), spaceIDs: [1])
        })
        let planningRead = rig.fullReadCount + 1
        rig.onMove = {
            guard rig.moves.last?.identity == attempted.identity else { return }
            rig.current = DesktopSnapshot(displays: rig.current.displays, windows: rig.current.windows.map { window in
                guard window.identity == attempted.identity else { return window }
                return WindowSnapshot(identity: window.identity, title: window.title,
                    frame: .init(x: 20, y: 20, width: 100, height: 100), spaceIDs: [1])
            })
        }
        rig.onFullRead = {
            // Planning, move revalidation, and failed move verification precede the final inventory.
            guard rig.fullReadCount == planningRead + 2 else { return }
            rig.current = DesktopSnapshot(displays: rig.current.displays, windows: rig.current.windows + [
                WindowSnapshot(identity: missing.identity, title: missing.title,
                    frame: .init(x: 20, y: 20, width: 100, height: 100), spaceIDs: [1])
            ])
        }
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(rig.moves.filter { $0.identity == attempted.identity }.count, 1)
        XCTAssertEqual(rig.moves.filter { $0.identity == missing.identity }.count, 1)
        XCTAssertEqual(rig.moves.last?.spaceID, 12)
        XCTAssertEqual(rig.current.windows.first { $0.identity == missing.identity }?.spaceIDs, [12])
        XCTAssertEqual(rig.current.windows.first { $0.identity == missing.identity }?.frame.x, 1020)
        XCTAssertEqual(rig.current.windows.first { $0.identity == attempted.identity }?.spaceIDs, [1])
        XCTAssertEqual(rig.placements.map(\.spaceID), [10, 11, 12])
        XCTAssertEqual(rig.sessionCount, 1)
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertTrue(rig.additions.isEmpty)
        XCTAssertEqual(rig.saved, profiles)
        XCTAssertTrue(coordinator.status.hasPrefix("Partial restoration"))
    }

    func testOpenMenuTracksDetectionAndChangesSaveTargetInPlace() async throws {
        let rig = Rig()
        let coordinator = rig.coordinator()
        let delegate = AppDelegate(coordinator: coordinator, hasAccessibility: { true })
        _ = NSApplication.shared
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = delegate.statusMenu
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        defer {
            delegate.menuDidClose(menu)
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        let profile = try XCTUnwrap(menu.item(withTitle: "Checking display setup…"))
        let save = try XCTUnwrap(menu.item(withTitle: "Save This Layout…"))
        XCTAssertFalse(save.isEnabled)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(profile.title, "MacBook")
        XCTAssertEqual(profile.subtitle, "1 display · 3 desktops")
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.representedObject as? ProfileTopology, .portable)

        rig.current = Rig.originalDesktops(monitorName: "DELL U2723QE")
        coordinator.receive(.screensChanged)
        XCTAssertNil(save.representedObject)
        XCTAssertFalse(save.isEnabled)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(profile.title, "DELL U2723QE")
        XCTAssertEqual(profile.subtitle, "No saved profile · 3 desktops · ID onitor")
        XCTAssertTrue(menu.item(withTitle: "Save Layout for DELL U2723QE…") === save)
        XCTAssertEqual(save.representedObject as? ProfileTopology, .external(displayID: "monitor"))
        XCTAssertTrue(save.isEnabled)
    }

    func testPartialRestoreWithZeroMovesIsAbsentFromCurrentAndPreviousMenuMessages() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = DesktopSnapshot(displays: rig.current.displays, windows: [])
        let coordinator = rig.coordinator()
        let delegate = AppDelegate(coordinator: coordinator, hasAccessibility: { true })
        _ = NSApplication.shared
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = delegate.statusMenu
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        defer {
            delegate.menuDidClose(menu)
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        await coordinator.waitUntilIdle()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        let result = try XCTUnwrap(coordinator.lastRestorationResult)
        XCTAssertEqual(result.summary, "Partial restoration · 0 moves")
        func visibleMessages() -> [String] {
            menu.items.filter { !$0.isHidden }.flatMap { [$0.title, $0.subtitle ?? ""] }
        }
        XCTAssertFalse(visibleMessages().contains(where: { $0.contains(result.summary) }))
        XCTAssertFalse(visibleMessages().contains(try XCTUnwrap(result.details.first)))
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertFalse(visibleMessages().contains(where: { $0.contains(result.summary) }))
        XCTAssertTrue(visibleMessages().contains("MacBook"))
    }

    func testThreeReturnedDesktopsNeedOnlyFreshPlanningAndFinalWindowInventories() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        let coordinator = rig.coordinator()
        rig.onFullRead = {
            XCTAssertEqual(rig.placements.count, 3)
            XCTAssertEqual(rig.finishCount, 1, "Mission Control must close before the window inventory")
        }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 3)
        XCTAssertEqual(rig.sessionCount, 1)
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertEqual(rig.fullReadCount, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testPortableAndReadyExternalProfilesDoNotCreateRecoverySession() async throws {
        for snapshot in [Rig.snapshot(), Rig.originalDesktops()] {
            let rig = Rig()
            rig.current = snapshot
            rig.saved = [try LayoutProfile.capture(snapshot: snapshot)]
            let coordinator = rig.coordinator()
            coordinator.onChange = { XCTAssertNil(coordinator.restorationPhase) }
            coordinator.restoreNow()
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.sessionCount, 0)
            XCTAssertEqual(rig.finishCount, 0)
            XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        }
    }

    func testCleanupFailureStopsWindowInventoryAndCannotAutomaticallyRetry() async throws {
        for gestureFails in [false, true] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
            rig.current = Rig.originalDesktops(migrated: true)
            rig.placeNoOp = gestureFails
            rig.finishFails = true
            let coordinator = rig.coordinator(automatic: true)
            coordinator.start()
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.count, gestureFails ? 1 : 3)
            XCTAssertEqual(rig.finishCount, 1, "A failed finish must not be attempted again by error cleanup")
            XCTAssertEqual(rig.fullReadCount, 0)
            XCTAssertTrue(rig.moves.isEmpty)
            XCTAssertTrue(coordinator.status.contains("MissionControlCloseFailure"))
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.sessionCount, 1)
            XCTAssertEqual(rig.finishCount, 1)
            XCTAssertTrue(coordinator.status.contains("Restore Now"))
        }
    }

    func testManualMissionControlClosureBetweenActionsDoesNotStartAnotherSession() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        rig.placeFailureAt = 2
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 2)
        XCTAssertEqual(rig.sessionCount, 1)
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertEqual(rig.fullReadCount, 0)
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 2)
        XCTAssertEqual(rig.sessionCount, 1)
        XCTAssertTrue(coordinator.status.contains("Restore Now"))
    }

    func testCancellationWaitsForCleanupBeforeAllowingAnotherRecovery() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        let coordinator = rig.coordinator(automatic: true)
        var continuation: CheckedContinuation<Void, Never>?
        rig.onPlace = { coordinator.receive(.locked) }
        rig.onFinishAsync = {
            await withCheckedContinuation { continuation = $0 }
        }
        coordinator.start()
        while continuation == nil { await Task.yield() }
        coordinator.receive(.unlocked)
        await Task.yield()
        XCTAssertEqual(rig.sessionCount, 1)
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertEqual(rig.loads, 1, "The next restore must wait for cleanup")
        XCTAssertEqual(rig.fullReadCount, 0)
        rig.onFinishAsync = nil
        continuation?.resume()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 1)
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertTrue(coordinator.status.contains("Restore Now"))
    }

    func testPlanningFailureAfterVerifiedGestureAndSuccessfulCleanupDoesNotBlockAutomaticRetry() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        let migrated = Rig.originalDesktops(migrated: true)
        rig.current = DesktopSnapshot(displays: migrated.displays.map { display in
            DisplaySnapshot(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame,
                spaces: display.isBuiltIn ? display.spaces.filter { $0.id == 10 || $0.id == 11 } : display.spaces)
        }, windows: migrated.windows)
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 1, "The second return would leave no ordinary desktop on the built-in display")
        XCTAssertEqual(rig.finishCount, 1)
        XCTAssertEqual(rig.fullReadCount, 0)
        XCTAssertFalse(coordinator.status.contains("Restore Now"))
        rig.current = migrated
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.sessionCount, 2)
        XCTAssertEqual(rig.finishCount, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testFreshFullInventoryMustMatchStabilizedStructureBeforeSavingOrMoving() async throws {
        for saving in [false, true] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
            let originalProfile = rig.saved
            rig.current = Rig.snapshot(space: 2)
            rig.fullReadings = [Rig.snapshot(external: true)]
            let coordinator = rig.coordinator()
            if saving { coordinator.saveCurrent(external: false) } else { coordinator.restoreNow() }
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.saved, originalProfile)
            XCTAssertTrue(rig.moves.isEmpty)
            XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
            XCTAssertNil(coordinator.detectedTopology)
            XCTAssertNil(coordinator.restorationPhase)
        }
    }

    func testIncompleteOrUnpermittedFreshInventoryNeverSavesOrMoves() async throws {
        for saving in [false, true] {
            for permission in [false, true] {
                let rig = Rig()
                rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
                let originalProfile = rig.saved
                rig.current = Rig.snapshot(space: 2)
                rig.fullReadings = [DesktopSnapshot(displays: rig.current.displays, windows: rig.current.windows,
                    hasAccessibilityPermission: permission, isComplete: !permission)]
                let coordinator = rig.coordinator()
                if saving { coordinator.saveCurrent(external: false) } else { coordinator.restoreNow() }
                await coordinator.waitUntilIdle()
                XCTAssertEqual(rig.saved, originalProfile)
                XCTAssertTrue(rig.moves.isEmpty)
                XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
            }
        }
    }

    func testCancellationAfterFreshInventoryNeverSavesOrMoves() async throws {
        for saving in [false, true] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
            let originalProfile = rig.saved
            rig.current = Rig.snapshot(space: 2)
            let coordinator = rig.coordinator()
            rig.onFullRead = { coordinator.receive(.locked) }
            if saving { coordinator.saveCurrent(external: false) } else { coordinator.restoreNow() }
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.fullReadCount, 1)
            XCTAssertEqual(rig.saved, originalProfile)
            XCTAssertTrue(rig.moves.isEmpty)
            XCTAssertNil(coordinator.restorationPhase)
        }
    }

    func testStaleFullInventoryAfterThreeDesktopReturnsDiscardsWindowPlan() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        rig.fullReadings = [rig.current]
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 3)
        XCTAssertEqual(rig.fullReadCount, 1)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
    }

    func testCancellationOfFreshInventoryAfterThirdDesktopReturnPreventsWindowMoves() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        let coordinator = rig.coordinator()
        rig.onFullRead = { coordinator.receive(.locked) }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 3)
        XCTAssertEqual(rig.fullReadCount, 1)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertNil(coordinator.restorationPhase)
    }

    func testInitialInspectionReadsOnlyDisplayStructure() async {
        let rig = Rig()
        let coordinator = rig.coordinator()
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.displayReadCount, 3)
        XCTAssertEqual(rig.fullReadCount, 0)
        XCTAssertTrue(coordinator.status.hasPrefix("Ready"))
    }

    func testPhaseStartsOnlyForRevalidatedWindowMovementAndCoversPartialVerification() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        rig.failuresRemaining = 1
        let coordinator = rig.coordinator()
        var phases: [LayoutCoordinator.RestorationPhase] = []
        var reportedPartial = false
        coordinator.onChange = {
            if let phase = coordinator.restorationPhase { phases.append(phase) }
            if !reportedPartial, coordinator.status.hasPrefix("Partial restoration") {
                reportedPartial = true
                XCTAssertEqual(coordinator.restorationPhase, .verifying)
            }
        }
        rig.onFullRead = {
            if rig.fullReadCount <= 2 { XCTAssertNil(coordinator.restorationPhase) }
            if rig.fullReadCount >= 4 { XCTAssertEqual(coordinator.restorationPhase, .verifying) }
        }
        rig.onMove = { XCTAssertEqual(coordinator.restorationPhase, .placingWindows) }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(reportedPartial)
        XCTAssertTrue(phases.contains(.placingWindows))
        XCTAssertTrue(phases.contains(.verifying))
        XCTAssertFalse(phases.contains(.recoveringDesktops))
        XCTAssertNil(coordinator.restorationPhase)
    }

    func testInspectionSavingMissingProfileAndAlreadyCorrectWindowsNeverShowPhase() async throws {
        let rig = Rig()
        let coordinator = rig.coordinator()
        coordinator.onChange = { XCTAssertNil(coordinator.restorationPhase) }
        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        coordinator.saveCurrent(external: false)
        await coordinator.waitUntilIdle()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        rig.current = DesktopSnapshot(displays: rig.current.displays, windows: [])
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.status.hasPrefix("Partial restoration"))
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testWindowCorrectedDuringRevalidationDoesNotShowPhase() async throws {
        let rig = Rig()
        let saved = rig.current
        rig.saved = [try LayoutProfile.capture(snapshot: saved)]
        rig.current = Rig.snapshot(space: 2)
        let coordinator = rig.coordinator()
        coordinator.onChange = { XCTAssertNil(coordinator.restorationPhase) }
        rig.onFullRead = { if rig.fullReadCount == 1 { rig.current = saved } }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testDesktopRecoveryPhaseCoversCleanupThenFinalVerification() async throws {
        for creating in [false, true] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: creating ? Rig.threeExternalDesktops() : Rig.originalDesktops())]
            rig.current = creating ? Rig.threeExternalDesktops(reconnected: true) : Rig.originalDesktops(migrated: true)
            let coordinator = rig.coordinator()
            var continuation: CheckedContinuation<Void, Never>?
            rig.onAdd = { XCTAssertEqual(coordinator.restorationPhase, .recoveringDesktops) }
            rig.onPlace = { XCTAssertEqual(coordinator.restorationPhase, .recoveringDesktops) }
            rig.onFinishAsync = {
                XCTAssertEqual(coordinator.restorationPhase, .recoveringDesktops)
                await withCheckedContinuation { continuation = $0 }
            }
            rig.onFullRead = {
                if rig.fullReadCount == 1 { XCTAssertEqual(coordinator.restorationPhase, .verifying) }
            }
            coordinator.restoreNow()
            while continuation == nil { await Task.yield() }
            XCTAssertEqual(coordinator.restorationPhase, .recoveringDesktops)
            rig.onFinishAsync = nil
            continuation?.resume()
            await coordinator.waitUntilIdle()
            XCTAssertNil(coordinator.restorationPhase)
            XCTAssertEqual(rig.sessionCount, 1)
            XCTAssertEqual(rig.finishCount, 1)
        }
    }

    func testFailedDesktopRecoveryKeepsPhaseUntilCleanupFinishes() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        rig.placeNoOp = true
        let coordinator = rig.coordinator()
        var continuation: CheckedContinuation<Void, Never>?
        rig.onFinishAsync = { await withCheckedContinuation { continuation = $0 } }
        coordinator.restoreNow()
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(coordinator.restorationPhase, .recoveringDesktops)
        continuation?.resume()
        await coordinator.waitUntilIdle()
        XCTAssertNil(coordinator.restorationPhase)
        XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
    }

    func testCancellationAndReplacementHidePhaseBeforeSuspendedMoveReturns() async throws {
        for action in 0..<8 {
            let rig = Rig()
            let saved = rig.current
            rig.saved = [try LayoutProfile.capture(snapshot: saved)]
            rig.current = Rig.snapshot(space: 2)
            let coordinator = rig.coordinator()
            var continuation: CheckedContinuation<Void, Never>?
            rig.onMoveAsync = { await withCheckedContinuation { continuation = $0 } }
            coordinator.restoreNow()
            while continuation == nil { await Task.yield() }
            XCTAssertEqual(coordinator.restorationPhase, .placingWindows)
            switch action {
            case 0: coordinator.receive(.screensChanged)
            case 1: coordinator.receive(.willSleep)
            case 2: coordinator.receive(.locked)
            case 3: coordinator.stop()
            case 4: coordinator.setAutomatic(false)
            case 5: coordinator.saveCurrent(external: false)
            case 6: coordinator.restoreNow()
            default: coordinator.start()
            }
            XCTAssertNil(coordinator.restorationPhase)
            rig.current = saved
            coordinator.onChange = { XCTAssertNil(coordinator.restorationPhase) }
            rig.onMoveAsync = nil
            continuation?.resume()
            await coordinator.waitUntilIdle()
            XCTAssertNil(coordinator.restorationPhase)
            XCTAssertEqual(rig.maximumConcurrentMoves, 1)
        }
    }

    func testCancellationAtFirstPhaseDoesNotBlockAnUnattemptedDesktopGesture() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        let coordinator = rig.coordinator(automatic: true)
        var interrupted = false
        coordinator.onChange = {
            if !interrupted, coordinator.restorationPhase == .recoveringDesktops {
                interrupted = true
                coordinator.receive(.locked)
            }
        }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(rig.placements.isEmpty)
        XCTAssertNil(coordinator.restorationPhase)
        coordinator.onChange = nil
        coordinator.receive(.unlocked)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 3)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testCancelledDesktopCleanupCannotRevivePhaseAfterUnlock() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        let coordinator = rig.coordinator(automatic: true)
        var continuation: CheckedContinuation<Void, Never>?
        rig.onPlace = {
            XCTAssertEqual(coordinator.restorationPhase, .recoveringDesktops)
            coordinator.receive(.locked)
            XCTAssertNil(coordinator.restorationPhase)
        }
        rig.onFinishAsync = { await withCheckedContinuation { continuation = $0 } }
        coordinator.start()
        while continuation == nil { await Task.yield() }
        coordinator.onChange = { XCTAssertNil(coordinator.restorationPhase) }
        coordinator.receive(.unlocked)
        XCTAssertNil(coordinator.restorationPhase)
        rig.onFinishAsync = nil
        continuation?.resume()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 1)
        XCTAssertEqual(rig.sessionCount, 1)
    }

    func testDistinctMonitorProfilesSurviveRoundTripThroughPortableWithRealStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = Rig()
        let store = ProfileStore(directory: directory)
        rig.store = store
        let home = Rig.originalDesktops()
        let office = Rig.originalDesktops(stableUUIDs: false, monitorID: "office", spaceOffset: 1000)
        let coordinator = rig.coordinator(automatic: true)
        for (snapshot, external) in [(home, true), (Rig.snapshot(), false), (office, true)] {
            rig.current = snapshot
            coordinator.saveCurrent(external: external)
            await coordinator.waitUntilIdle()
        }
        let homeProfile = try XCTUnwrap(store.load(.external(displayID: "monitor")))
        let homeRegistry = try XCTUnwrap(store.loadExternalDesktopRegistry(profile: homeProfile))
        let officeProfile = try XCTUnwrap(store.load(.external(displayID: "office")))
        let officeRegistry = try XCTUnwrap(store.loadExternalDesktopRegistry(profile: officeProfile))
        XCTAssertNotEqual(homeRegistry.displayID, officeRegistry.displayID)
        func connect(_ snapshot: DesktopSnapshot) async {
            rig.moves.removeAll()
            rig.operations.removeAll()
            rig.current = snapshot
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
        }
        func migrated(_ id: String, offset: UInt64) -> DesktopSnapshot {
            let snapshot = Rig.originalDesktops(migrated: true, stableUUIDs: id != "office", monitorID: id, spaceOffset: offset)
            let windows = snapshot.windows.enumerated().map { index, window in
                guard index == 0 else { return window }
                return WindowSnapshot(identity: window.identity, title: window.title, frame: window.frame, spaceIDs: [1])
            }
            return DesktopSnapshot(displays: snapshot.displays, windows: windows)
        }
        await connect(home)
        XCTAssertTrue(rig.operations.isEmpty)
        await connect(Rig.snapshot(space: 2))
        XCTAssertEqual(rig.operations, ["move:1", "move:1"])
        XCTAssertEqual(Set(rig.moves.map(\.displayID)), ["builtin"])
        await connect(migrated("office", offset: 1000))
        XCTAssertEqual(rig.operations, ["place:1010", "place:1011", "place:1012", "move:1010"])
        XCTAssertEqual(rig.moves.first?.displayID, "office")
        await connect(Rig.snapshot(space: 2))
        XCTAssertEqual(rig.operations, ["move:1", "move:1"])
        XCTAssertEqual(Set(rig.moves.map(\.displayID)), ["builtin"])
        await connect(migrated("monitor", offset: 0))
        XCTAssertEqual(rig.operations, ["place:10", "place:11", "place:12", "move:10"])
        XCTAssertEqual(rig.moves.first?.displayID, "monitor")
        XCTAssertEqual(try store.load(.external(displayID: "monitor")), homeProfile)
        XCTAssertEqual(try store.load(.external(displayID: "office")), officeProfile)
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: homeProfile), homeRegistry)
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: officeProfile), officeRegistry)
    }

    func testSavingOrFailingAnotherProfileDoesNotClearUncertainDesktopGestureBlock() async throws {
        for saveSucceeds in [true, false] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
            rig.current = Rig.originalDesktops(migrated: true)
            rig.placeNoOp = true
            let coordinator = rig.coordinator(automatic: true)
            coordinator.start()
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.count, 1)
            rig.current = Rig.originalDesktops(monitorID: "office", spaceOffset: 1000)
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            coordinator.saveCurrent(external: true,
                expectedTopology: .external(displayID: saveSucceeds ? "office" : "other"))
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.saved.contains { $0.topology == .external(displayID: "office") }, saveSucceeds)
            rig.placeNoOp = false
            rig.current = Rig.originalDesktops(migrated: true)
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.count, 1)
            XCTAssertEqual(rig.sessionCount, 1)
            XCTAssertTrue(coordinator.status.contains("Restore Now"))
        }
    }

    func testOpenMenuNamesTheConnectedMonitorAndLetsNewMonitorBeSaved() async throws {
        _ = NSApplication.shared
        let rig = Rig()
        let home = Rig.originalDesktops(monitorName: "Home Monitor")
        let office = Rig.originalDesktops(monitorID: "office", monitorName: "Office Monitor")
        rig.current = home
        rig.saved = [try LayoutProfile.capture(snapshot: home)]
        let coordinator = rig.coordinator()
        let delegate = AppDelegate(coordinator: coordinator, hasAccessibility: { true })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let menu = delegate.statusMenu
        delegate.menuWillOpen(menu)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(menu.item(withTitle: "Save Layout for Home Monitor…")?.isEnabled, true)
        XCTAssertEqual(menu.item(withTitle: "Restore Now")?.isEnabled, true)

        rig.current = office
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(menu.item(withTitle: "Office Monitor")?.subtitle?.contains("No saved profile") == true)
        XCTAssertEqual(menu.item(withTitle: "Save Layout for Office Monitor…")?.isEnabled, true)
        XCTAssertEqual(menu.item(withTitle: "Restore Now")?.isEnabled, false)
        coordinator.saveCurrent(external: true, expectedTopology: .external(displayID: "office"))
        await coordinator.waitUntilIdle()
        XCTAssertFalse(menu.item(withTitle: "Office Monitor")?.subtitle?.contains("No saved profile") == true)
        XCTAssertEqual(menu.item(withTitle: "Restore Now")?.isEnabled, true)

        rig.profileLoadFails = true
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
        XCTAssertFalse(menu.item(withTitle: "Office Monitor")?.subtitle?.contains("No saved profile") == true)

        rig.profileLoadFails = false
        rig.current = Rig.originalDesktops(monitorID: "office", monitorName: " ")
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(menu.item(withTitle: "Save Layout for Monitor office…")?.isEnabled, true)
    }

    func testDetectedTopologyNeedsStableReadingsAndUpdatesWithoutAutomaticRestoration() async {
        let rig = Rig()
        let coordinator = rig.coordinator()
        rig.onDisplayRead = { XCTAssertNil(coordinator.detectedTopology) }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedTopology, .portable)
        rig.current = Rig.snapshot(external: true)
        coordinator.receive(.screensChanged)
        XCTAssertNil(coordinator.detectedTopology)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedTopology, .external(displayID: "monitor"))
        coordinator.receive(.willSleep)
        XCTAssertNil(coordinator.detectedTopology)
        rig.current = Rig.snapshot()
        coordinator.receive(.didWake)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedTopology, .portable)
        coordinator.receive(.locked)
        XCTAssertNil(coordinator.detectedTopology)
        coordinator.receive(.unlocked)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedTopology, .portable)
        XCTAssertEqual(rig.fullReadCount, 0)
        XCTAssertEqual(rig.loads, 1)
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testDetectedDesktopCountUsesOrdinarySpacesOfTheRelevantDisplay() async {
        let rig = Rig()
        let original = Rig.snapshot(external: true)
        rig.current = DesktopSnapshot(displays: original.displays.map { display in
            DisplaySnapshot(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame,
                spaces: display.isBuiltIn ? display.spaces : [
                    SpaceSnapshot(id: 10, kind: .ordinary), SpaceSnapshot(id: 11, kind: .fullScreen),
                    SpaceSnapshot(id: 12, kind: .ordinary), SpaceSnapshot(id: 13, kind: .splitView)
                ])
        }, windows: [])
        let coordinator = rig.coordinator()
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedDesktopCount, 2)
        XCTAssertEqual(rig.displayReadCount, 3)
        XCTAssertEqual(rig.fullReadCount, 0)
        rig.current = Rig.snapshot()
        coordinator.receive(.screensChanged)
        XCTAssertNil(coordinator.detectedTopology)
        XCTAssertNil(coordinator.detectedDesktopCount)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedDesktopCount, 3)
    }

    func testUncertainReadingsClearAPreviouslyDetectedConfiguration() async {
        for failure in 0..<5 {
            let rig = Rig()
            let coordinator = rig.coordinator()
            coordinator.start()
            await coordinator.waitUntilIdle()
            XCTAssertEqual(coordinator.detectedTopology, .portable)
            XCTAssertEqual(coordinator.detectedDesktopCount, 3)
            switch failure {
            case 0:
                rig.current = DesktopSnapshot(displays: rig.current.displays, windows: [], hasAccessibilityPermission: false)
            case 1:
                rig.readings = (0..<30).map { Rig.snapshot(external: $0.isMultiple(of: 2)) }
            case 2:
                rig.current = DesktopSnapshot(displays: rig.current.displays, windows: [], isComplete: false)
            case 3:
                rig.snapshotErrorsRemaining = 30
            default:
                let display = rig.current.displays[0]
                rig.current = DesktopSnapshot(displays: [display, display], windows: [])
            }
            coordinator.start()
            await coordinator.waitUntilIdle()
            XCTAssertNil(coordinator.detectedTopology)
            XCTAssertNil(coordinator.detectedDesktopCount)
            XCTAssertNil(coordinator.lastRestorationResult)
        }
    }

    func testFreshPermissionFailureClearsDetectedConfigurationWithoutSaving() async {
        let rig = Rig()
        let coordinator = rig.coordinator()
        coordinator.start()
        await coordinator.waitUntilIdle()
        rig.fullReadings = [DesktopSnapshot(displays: rig.current.displays, windows: [], hasAccessibilityPermission: false)]
        coordinator.saveCurrent(external: false)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(rig.saved.isEmpty)
        XCTAssertNil(coordinator.detectedTopology)
        XCTAssertNil(coordinator.detectedDesktopCount)
        XCTAssertNil(coordinator.lastRestorationResult)
    }

    func testSuccessfulRestorationResultSurvivesInspectionAndEnvironmentChanges() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        let summary = try XCTUnwrap(coordinator.lastRestorationResult?.summary)
        XCTAssertTrue(summary.hasPrefix("Restored · 2 moves"))
        XCTAssertEqual(coordinator.lastRestorationResult?.details, [])
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.status.hasPrefix("Ready"))
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
        coordinator.receive(.willSleep)
        XCTAssertNil(coordinator.detectedDesktopCount)
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
        rig.current = Rig.snapshot(external: true)
        coordinator.receive(.didWake)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.detectedTopology, .external(displayID: "monitor"))
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
        coordinator.saveCurrent(external: true)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
    }

    func testUnchangedAutomaticWakeDoesNotReplaceTheLastRestorationResult() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        let summary = try XCTUnwrap(coordinator.lastRestorationResult?.summary)
        coordinator.receive(.willSleep)
        coordinator.receive(.didWake)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.status, "Display setup unchanged")
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
        XCTAssertEqual(rig.moves.count, 2)
    }

    func testTopologyCancellationPreservesLastResultAndInvalidatesDesktopCount() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        let summary = try XCTUnwrap(coordinator.lastRestorationResult?.summary)
        rig.current = Rig.snapshot(space: 2)
        rig.fullReadings = [Rig.snapshot(external: true)]
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
        XCTAssertNil(coordinator.detectedTopology)
        XCTAssertNil(coordinator.detectedDesktopCount)
        rig.onMove = { coordinator.receive(.locked) }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, summary)
        XCTAssertNil(coordinator.detectedDesktopCount)
    }

    func testPartialAndFailedRestorationsPublishSessionResults() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        rig.failuresRemaining = 1
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, coordinator.status)
        XCTAssertTrue(coordinator.status.hasPrefix("Partial restoration"))
        XCTAssertEqual(coordinator.lastRestorationResult?.details, coordinator.details)
        XCTAssertFalse(coordinator.details.isEmpty)
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        rig.placeNoOp = true
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
        XCTAssertEqual(coordinator.lastRestorationResult?.summary, coordinator.status)
    }

    func testContextualSaveRejectsDifferentExternalMonitorAfterMenuWasOpened() async {
        let rig = Rig()
        rig.current = Rig.snapshot(external: true)
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: true, expectedTopology: .external(displayID: "previous-monitor"))
        await coordinator.waitUntilIdle()
        XCTAssertTrue(rig.saved.isEmpty)
        XCTAssertEqual(coordinator.detectedTopology, .external(displayID: "monitor"))
        XCTAssertTrue(coordinator.status.contains("Reopen the menu"))
        coordinator.saveCurrent(external: true, expectedTopology: .external(displayID: "monitor"))
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.saved.count, 1)
    }

    func testFailedDesktopGesturesStayBlockedAcrossAutomaticEventsButManualRetryCanRecover() async throws {
        for returning in [false, true] {
            let rig = Rig()
            let savedState = returning ? Rig.originalDesktops() : Rig.threeExternalDesktops()
            let disconnected = returning ? Rig.originalDesktops(migrated: true) : Rig.threeExternalDesktops(reconnected: true)
            rig.saved = [try LayoutProfile.capture(snapshot: savedState), try LayoutProfile.capture(snapshot: Rig.snapshot())]
            rig.current = disconnected
            rig.placeNoOp = returning
            rig.addNoOp = !returning
            let coordinator = rig.coordinator(automatic: true)
            coordinator.start()
            await coordinator.waitUntilIdle()
            for event in [LayoutCoordinator.Event.willSleep, .didWake, .locked, .unlocked, .screensChanged, .screensChanged] {
                coordinator.receive(event)
                await coordinator.waitUntilIdle()
            }
            XCTAssertEqual(rig.placements.count + rig.additions.count, 1)
            XCTAssertEqual(rig.sessionCount, 1)
            XCTAssertEqual(rig.finishCount, 1)
            XCTAssertTrue(coordinator.status.contains("Restore Now"))

            rig.current = Rig.snapshot(space: 2)
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.moves.count, 2, "The portable profile remains usable")
            rig.current = disconnected
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.count + rig.additions.count, 1, "Reconnect cannot authorize another gesture")

            rig.placeNoOp = false
            rig.addNoOp = false
            coordinator.restoreNow()
            await coordinator.waitUntilIdle()
            XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
            XCTAssertEqual(rig.placements.count, returning ? 4 : 0)
            XCTAssertEqual(rig.additions.count, returning ? 0 : 3)
            XCTAssertEqual(rig.sessionCount, 2)
            XCTAssertEqual(rig.finishCount, 2)
        }
    }

    func testCancellationAfterStartingDesktopGestureRequiresManualRetryAfterUnlock() async throws {
        for returning in [false, true] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: returning ? Rig.originalDesktops() : Rig.threeExternalDesktops())]
            rig.current = returning ? Rig.originalDesktops(migrated: true) : Rig.threeExternalDesktops(reconnected: true)
            let coordinator = rig.coordinator(automatic: true)
            if returning { rig.onPlace = { coordinator.receive(.locked) } }
            else { rig.onAdd = { coordinator.receive(.locked) } }
            coordinator.start()
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.finishCount, 1)
            rig.onPlace = nil
            rig.onAdd = nil
            coordinator.receive(.unlocked)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.count + rig.additions.count, 1)
            XCTAssertTrue(rig.moves.isEmpty)
            XCTAssertTrue(coordinator.status.contains("Restore Now"))
            coordinator.restoreNow()
            await coordinator.waitUntilIdle()
            XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        }
    }

    func testUncertainPostGestureVerificationBlocksAutomaticGesturesUntilManualRetry() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        rig.onAdd = {
            let changed = DesktopSnapshot(displays: rig.current.displays.map { display in
                DisplaySnapshot(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame,
                    spaces: display.spaces + (display.isBuiltIn ? [SpaceSnapshot(id: 999, kind: .ordinary)] : []))
            }, windows: rig.current.windows)
            rig.readings = Array(repeating: changed, count: 3)
        }
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        rig.onAdd = nil
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 1)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(coordinator.status.contains("Restore Now"))
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testExplicitExternalSaveRearmsAutomaticRecoveryForTheNewCapture() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        rig.addNoOp = true
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        rig.current = Rig.originalDesktops()
        coordinator.saveCurrent(external: true)
        await coordinator.waitUntilIdle()
        rig.addNoOp = false
        rig.current = Rig.originalDesktops(migrated: true)
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 1)
        XCTAssertEqual(rig.placements.count, 3)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testManualAndAutomaticReturnOriginalDesktopsWithUnmanagedWindowBeforeAnyCreation() async throws {
        for automatic in [false, true] {
            let rig = Rig()
            rig.current = Rig.originalDesktops()
            let coordinator = rig.coordinator(automatic: automatic)
            coordinator.saveCurrent(external: true)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.registrySaveCount, 1)
            let saved = rig.saved
            rig.current = Rig.originalDesktops(migrated: true)
            let unrelated = rig.current.windows.last!
            if automatic { coordinator.receive(.screensChanged) } else { coordinator.restoreNow() }
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.map(\.spaceID), [10, 11, 12])
            XCTAssertEqual(rig.operations, ["place:10", "place:11", "place:12"])
            XCTAssertEqual(rig.current.displays[1].spaces.map(\.id), [10, 11, 12, 100])
            XCTAssertEqual(rig.current.displays[0].spaces.map(\.id), [1, 2, 3])
            XCTAssertTrue(rig.additions.isEmpty)
            XCTAssertTrue(rig.moves.isEmpty)
            let observed = rig.current.windows.first { $0.identity == unrelated.identity }!
            XCTAssertEqual(observed.spaceIDs, unrelated.spaceIDs)
            XCTAssertEqual(observed.title, unrelated.title)
            XCTAssertTrue(rig.current.displays[1].frame.containsCenter(of: observed.frame))
            XCTAssertTrue(coordinator.status.contains("3 desktops returned"))
            XCTAssertTrue(coordinator.details.contains { $0.contains("1 extra desktop") })
            coordinator.restoreNow()
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.placements.count, 3)
            XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
            let loads = rig.loads
            coordinator.receive(.willSleep)
            coordinator.receive(.didWake)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.loads, loads + (automatic ? 0 : 1))
            XCTAssertEqual(rig.placements.count, 3)
            XCTAssertEqual(rig.saved, saved)
            XCTAssertEqual(rig.registrySaveCount, 1, "Hotplug never rewrites the saved original identities")
        }
    }

    func testOriginalsAreReorderedEvenWhenExternalAlreadyHasEnoughDesktops() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(reordered: true)
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.current.displays[1].spaces.map(\.id), [10, 11, 12])
        XCTAssertFalse(rig.placements.isEmpty)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(rig.additions.isEmpty)
    }

    func testExplicitSaveCanReturnLiveSpaceIDsWithoutUUIDOnlyWithinSameCoordinatorSession() async throws {
        let rig = Rig()
        rig.current = Rig.originalDesktops(stableUUIDs: false)
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: true)
        await coordinator.waitUntilIdle()
        rig.current = Rig.originalDesktops(migrated: true, stableUUIDs: false)
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.map(\.spaceID), [10, 11, 12])
        XCTAssertTrue(rig.additions.isEmpty)
        XCTAssertEqual(rig.registrySaveCount, 1)
    }

    func testFailedReturnStopsWithoutCreatingDuplicatesOrMovingWindowsSeparately() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        rig.placeNoOp = true
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 1)
        XCTAssertTrue(rig.additions.isEmpty)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertEqual(rig.loads, 1)
        XCTAssertTrue(coordinator.status.contains("Could not verify the desktop return"))
    }

    func testCancellationDuringReturnDiscardsFollowingDesktopsAndWindowMoves() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        rig.current = Rig.originalDesktops(migrated: true)
        let coordinator = rig.coordinator(automatic: true)
        rig.onPlace = { coordinator.receive(.locked) }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.placements.count, 1)
        XCTAssertTrue(rig.additions.isEmpty)
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testDuplicateOriginalIdentityIsNotDraggedOrReplaced() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.originalDesktops())]
        let state = Rig.originalDesktops(migrated: true)
        let duplicate = SpaceSnapshot(id: 100, kind: .ordinary, stableUUID: state.displays[0].spaces[3].stableUUID)
        rig.current = DesktopSnapshot(displays: [state.displays[0], .init(id: "monitor", isBuiltIn: false,
            frame: state.displays[1].frame, spaces: [duplicate])], windows: state.windows)
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(rig.placements.isEmpty)
        XCTAssertTrue(rig.additions.isEmpty)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(coordinator.status.hasPrefix("Pending"))
    }

    func testReconnectRecreatesMissingExternalOrdinaryDesktopsBeforeMovingWindows() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.map(\.spaceID), [100, 101, 102])
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        XCTAssertEqual(rig.current.displays.last?.spaces.count, 3)
        XCTAssertEqual(rig.additions, ["monitor", "monitor"])
        XCTAssertEqual(rig.operations, ["add", "add", "move:100", "move:101", "move:102"])
        XCTAssertTrue(coordinator.status.contains("2 desktops created"))
        XCTAssertEqual(rig.registrySaveCount, 2)
        let saved = rig.saved
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 2)
        XCTAssertEqual(rig.moves.count, 3)
        XCTAssertTrue(coordinator.status.contains("0 moves"))
        XCTAssertEqual(rig.saved, saved)
    }

    func testAutomaticReconnectUsesFreshDestinationsAndNeverDeletesMigratedDesktops() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        for firstID: UInt64 in [100, 200] {
            rig.current = Rig.threeExternalDesktops(reconnected: true, firstID: firstID)
            let migrated = rig.current.displays[0]
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
            XCTAssertEqual(rig.current.displays[0], migrated)
            XCTAssertEqual(Array(rig.moves.suffix(3)).map(\.spaceID), [firstID, firstID + 1, firstID + 2])
            XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
            rig.current = DesktopSnapshot(displays: [migrated], windows: rig.current.windows)
            coordinator.receive(.screensChanged)
            await coordinator.waitUntilIdle()
        }
        XCTAssertEqual(rig.additions, Array(repeating: "monitor", count: 4))
        XCTAssertEqual(rig.saved.count, 1)
    }

    func testNoEffectAdditionStopsAutomaticRestoreWithoutAnotherPressOrWindowMove() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        rig.addNoOp = true
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 1)
        XCTAssertEqual(rig.loads, 1)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(coordinator.status.contains("did not create a desktop"))
    }

    func testCancellationDuringCreationStopsRemainingCreationAndMovement() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        let coordinator = rig.coordinator(automatic: true)
        rig.onAdd = { coordinator.receive(.locked) }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 1)
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testDisconnectDuringCreationDoesNotCreateOnBuiltInDisplayOrRetryOldTopology() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        let coordinator = rig.coordinator(automatic: true)
        rig.onAdd = {
            rig.current = DesktopSnapshot(displays: [rig.current.displays[0]], windows: rig.current.windows)
            coordinator.receive(.screensChanged)
        }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions, ["monitor"])
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertEqual(rig.loads, 2)
    }

    func testUnknownMonitorAndNonOrdinarySequenceDoNotCreateDesktops() async throws {
        for (id, kind) in [("another-monitor", SpaceKind.ordinary), ("monitor", SpaceKind.fullScreen)] {
            let rig = Rig()
            rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
            let state = Rig.threeExternalDesktops(reconnected: true)
            let monitor = state.displays[1]
            rig.current = DesktopSnapshot(displays: [state.displays[0], DisplaySnapshot(id: id, isBuiltIn: false,
                frame: monitor.frame, spaces: [SpaceSnapshot(id: 100, kind: kind)])], windows: state.windows)
            let coordinator = rig.coordinator()
            coordinator.restoreNow()
            await coordinator.waitUntilIdle()
            XCTAssertTrue(rig.additions.isEmpty)
        }
    }

    func testPostCreationStableReferenceObservesNewWindowInventoryBeforePlanning() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.threeExternalDesktops())]
        rig.current = Rig.threeExternalDesktops(reconnected: true)
        rig.onAdd = {
            if rig.additions.count == 2 {
                let target = rig.current.displays[1]
                rig.current = DesktopSnapshot(displays: rig.current.displays, windows: rig.current.windows.map { window in
                    WindowSnapshot(identity: window.identity, title: window.title,
                        frame: .init(x: target.frame.x + 20, y: 20, width: 100, height: 100),
                        spaceIDs: [UInt64(window.identity.windowID) + 99])
                })
            }
        }
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.additions.count, 2)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        XCTAssertGreaterThanOrEqual(rig.displayReadCount, 7)
    }

    func testExplicitSaveManualRestoreAndIdempotence() async throws {
        let rig = Rig()
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: false)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.saved.count, 1)
        let saved = rig.saved
        rig.current = Rig.snapshot(space: 2)
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 2)
        XCTAssertTrue(coordinator.status.contains("0 moves"))
        XCTAssertEqual(rig.saved, saved)
    }

    func testChangingActiveDesktopDoesNotInvalidateRemainingWindowMoves() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        let coordinator = rig.coordinator()
        rig.onMove = {
            rig.current = DesktopSnapshot(displays: rig.current.displays.map { display in
                DisplaySnapshot(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame,
                    spaces: display.spaces, currentSpaceID: display.spaces[2].id)
            }, windows: rig.current.windows)
        }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testWrongProfileChoiceNeverSaves() async {
        let rig = Rig()
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: true)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(rig.saved.isEmpty)
        XCTAssertTrue(coordinator.status.contains("Connect the external monitor"))
    }

    func testTransientReadFailureAndIncompleteSamplesDoNotCountAsStable() async {
        let rig = Rig()
        rig.snapshotErrorsRemaining = 1
        let incomplete = DesktopSnapshot(displays: rig.current.displays, windows: [], isComplete: false)
        rig.readings = [incomplete, incomplete, incomplete]
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: false)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.displayReadCount, 7)
        XCTAssertEqual(rig.saved.count, 1)
        XCTAssertEqual(rig.saved.first?.windows.count, 2)
    }

    func testSavingManyPendingWindowsPublishesJustTheCount() async throws {
        let rig = Rig()
        let original = try XCTUnwrap(rig.current.windows.first)
        let windows = [original] + (2...201).map { index in
            let identity = WindowIdentity(process: original.identity.process, windowID: UInt32(index),
                                          bundleIdentifier: original.identity.bundleIdentifier)
            return WindowSnapshot(identity: identity, title: "Documento \(index)", frame: original.frame, spaceIDs: [1, 2])
        }
        rig.current = DesktopSnapshot(displays: rig.current.displays, windows: windows)
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: false)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.saved.first?.windows.count, windows.count)
        XCTAssertEqual(coordinator.status, "Layout saved · MacBook · 200 pending")
        XCTAssertTrue(coordinator.details.isEmpty)
    }

    func testScreenChangeCancelsManualRestoreWithAutomaticDisabled() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        let coordinator = rig.coordinator()
        rig.onMove = {
            rig.current = Rig.snapshot(external: true)
            coordinator.receive(.screensChanged)
        }
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 1)
        XCTAssertEqual(rig.loads, 2, "Inspecting the new monitor reads its profile without restoring it")
        XCTAssertFalse(coordinator.automaticEnabled)
    }

    func testMissingWindowHasIndividualDiagnostic() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = DesktopSnapshot(displays: rig.current.displays, windows: [])
        let coordinator = rig.coordinator()
        coordinator.restoreNow()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.details.count, 2)
        XCTAssertTrue(coordinator.details[0].contains("window"))
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testUnchangedWakeAndUnlockDoNotRestoreAgain() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.loads, 1)
        coordinator.receive(.willSleep)
        coordinator.receive(.locked)
        coordinator.receive(.didWake)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.loads, 1)
        coordinator.receive(.unlocked)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.loads, 1)
        XCTAssertTrue(rig.moves.isEmpty)
    }

    func testPendingMovementRetriesAfterWake() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current)]
        rig.current = Rig.snapshot(space: 2)
        rig.failuresRemaining = 1
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.status.hasPrefix("Partial restoration"))
        coordinator.receive(.willSleep)
        coordinator.receive(.didWake)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        XCTAssertEqual(rig.loads, 2)
        XCTAssertEqual(rig.moves.count, 3)
    }

    func testWakeRestoresChangedConfigurationInBothDirections() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: rig.current), try LayoutProfile.capture(snapshot: Rig.snapshot(external: true))]
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        await coordinator.waitUntilIdle()
        for external in [true, false] {
            coordinator.receive(.willSleep)
            rig.current = Rig.snapshot(external: external, space: 2)
            coordinator.receive(.didWake)
            await coordinator.waitUntilIdle()
            XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
        }
        XCTAssertEqual(rig.moves.count, 4)
    }

    func testBurstWaitsForThreeMatchingReadingsAndRestoresFinalProfile() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.snapshot(external: true))]
        rig.readings = [Rig.snapshot(), Rig.snapshot(external: true), Rig.snapshot(), Rig.snapshot(external: true)]
        rig.current = Rig.snapshot(external: true, space: 2)
        let coordinator = rig.coordinator(automatic: true)
        coordinator.start()
        coordinator.receive(.screensChanged)
        coordinator.receive(.screensChanged)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.loads, 1)
        XCTAssertEqual(rig.moves.count, 2)
        XCTAssertEqual(Set(rig.moves.map(\.displayID)), ["builtin", "monitor"])
        XCTAssertGreaterThanOrEqual(rig.displayReadCount, 6)
    }

    func testDisconnectDuringMoveDiscardsRemainingOldMovesAndRecalculates() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.snapshot()), try LayoutProfile.capture(snapshot: Rig.snapshot(external: true))]
        rig.current = Rig.snapshot(external: true, space: 2)
        let coordinator = rig.coordinator(automatic: true)
        rig.onMove = {
            rig.onMove = nil
            rig.current = Rig.snapshot()
            coordinator.receive(.screensChanged)
        }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 1)
        XCTAssertEqual(rig.maximumConcurrentMoves, 1)
        XCTAssertEqual(rig.loads, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testRecalculationWaitsForSuspendedMoveToFinish() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.snapshot()), try LayoutProfile.capture(snapshot: Rig.snapshot(external: true))]
        rig.current = Rig.snapshot(external: true, space: 2)
        let coordinator = rig.coordinator(automatic: true)
        var continuation: CheckedContinuation<Void, Never>?
        rig.onMoveAsync = {
            await withCheckedContinuation { continuation = $0 }
        }
        coordinator.start()
        while continuation == nil { await Task.yield() }
        rig.current = Rig.snapshot()
        coordinator.receive(.screensChanged)
        await Task.yield()
        XCTAssertEqual(rig.loads, 1)
        XCTAssertEqual(rig.concurrentMoves, 1)
        rig.onMoveAsync = nil
        continuation?.resume()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 1)
        XCTAssertEqual(rig.maximumConcurrentMoves, 1)
        XCTAssertEqual(rig.loads, 2)
    }

    func testObservedConfigurationChangeRecalculatesEvenWithoutNotification() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.snapshot()), try LayoutProfile.capture(snapshot: Rig.snapshot(external: true))]
        rig.current = Rig.snapshot(external: true, space: 2)
        let coordinator = rig.coordinator(automatic: true)
        rig.onMove = {
            rig.onMove = nil
            rig.current = Rig.snapshot()
        }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 1)
        XCTAssertEqual(rig.loads, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testLockedSessionCancelsWithoutStartingAnotherMove() async throws {
        let rig = Rig()
        rig.saved = [try LayoutProfile.capture(snapshot: Rig.snapshot())]
        rig.current = Rig.snapshot(space: 2)
        let coordinator = rig.coordinator(automatic: true)
        rig.onMove = { coordinator.receive(.locked) }
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 1)
        rig.onMove = nil
        coordinator.receive(.unlocked)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.moves.count, 2)
        XCTAssertTrue(coordinator.status.hasPrefix("Restored"))
    }

    func testUnstableScreensReachDeadlineWithoutMovingOrSaving() async {
        let rig = Rig()
        rig.readings = (0..<30).map { Rig.snapshot(external: $0.isMultiple(of: 2)) }
        let coordinator = rig.coordinator()
        coordinator.saveCurrent(external: false)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(rig.displayReadCount, 30)
        XCTAssertTrue(rig.moves.isEmpty)
        XCTAssertTrue(rig.saved.isEmpty)
        XCTAssertTrue(coordinator.status.contains("did not stabilize"))
    }
}

@MainActor
private final class Rig {
    var current = Rig.snapshot()
    var readings: [DesktopSnapshot] = []
    var saved: [LayoutProfile] = []
    var store: ProfileStore?
    var moves: [WindowMove] = []
    var loads = 0
    var profileLoadFails = false
    var displayReadCount = 0
    var fullReadCount = 0
    var fullReadings: [DesktopSnapshot] = []
    var onFullRead: (() -> Void)?
    var onDisplayRead: (() -> Void)?
    var snapshotErrorsRemaining = 0
    var failuresRemaining = 0
    var onMove: (() -> Void)?
    var onMoveAsync: (() async -> Void)?
    var concurrentMoves = 0
    var maximumConcurrentMoves = 0
    var additions: [String] = []
    var operations: [String] = []
    var onAdd: (() -> Void)?
    var addNoOp = false
    var placements: [OrdinaryDesktopReturnStep] = []
    var placeNoOp = false
    var placeFailureAt: Int?
    var onPlace: (() -> Void)?
    var registry: ExternalDesktopRegistry?
    var registrySaveCount = 0
    var sessionCount = 0
    var finishCount = 0
    var finishFails = false
    var onFinishAsync: (() async -> Void)?
    var canConfirmPhysicalDisplays = true
    var pauseCount = 0

    func coordinator(automatic: Bool = false) -> LayoutCoordinator {
        LayoutCoordinator(dependencies: .init(snapshot: {
            self.fullReadCount += 1
            let snapshot = self.fullReadings.isEmpty ? self.current : self.fullReadings.removeFirst()
            self.onFullRead?()
            return snapshot
        }, displaySnapshot: {
            self.displayReadCount += 1
            self.onDisplayRead?()
            if self.snapshotErrorsRemaining > 0 {
                self.snapshotErrorsRemaining -= 1
                throw NSError(domain: "TransientRead", code: 1)
            }
            let snapshot = self.readings.isEmpty ? self.current : self.readings.removeFirst()
            return DesktopSnapshot(displays: snapshot.displays, windows: [],
                hasAccessibilityPermission: snapshot.hasAccessibilityPermission, isComplete: snapshot.isComplete, issues: snapshot.issues)
        }, move: { move, _ in
            self.moves.append(move)
            self.operations.append("move:\(move.spaceID)")
            self.concurrentMoves += 1
            self.maximumConcurrentMoves = max(self.maximumConcurrentMoves, self.concurrentMoves)
            defer { self.concurrentMoves -= 1 }
            if self.failuresRemaining > 0 {
                self.failuresRemaining -= 1
                throw NSError(domain: "SimulatedMoveFailure", code: 1)
            }
            self.current = DesktopSnapshot(displays: self.current.displays, windows: self.current.windows.map { window in
                guard window.identity == move.identity else { return window }
                let display = self.current.displays.first { $0.id == move.displayID }!
                return WindowSnapshot(identity: window.identity, title: window.title, frame: .init(x: display.frame.x + 20, y: display.frame.y + 20, width: 100, height: 100), spaceIDs: [move.spaceID])
            })
            self.onMove?()
            await self.onMoveAsync?()
        }, load: { topology in
            self.loads += 1
            if self.profileLoadFails { throw CocoaError(.fileReadCorruptFile) }
            if let store = self.store { return try store.load(topology) }
            return self.saved.first { $0.topology == topology }
        }, save: { profile in
            if let store = self.store { try store.save(profile); return }
            self.saved.removeAll { $0.topology == profile.topology }
            self.saved.append(profile)
        }, makeDesktopRecoverySession: {
            self.sessionCount += 1
            return .init(addOrdinaryDesktop: { displayID, expected in
                XCTAssertEqual(expected.displays, self.current.displays)
                self.additions.append(displayID)
                self.operations.append("add")
                if !self.addNoOp {
                    let nextID = self.current.displays.flatMap(\.spaces).map(\.id).max()! + 1
                    self.current = DesktopSnapshot(displays: self.current.displays.map { display in
                        guard display.id == displayID else { return display }
                        return DisplaySnapshot(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame,
                            spaces: display.spaces + [SpaceSnapshot(id: nextID, kind: .ordinary)])
                    }, windows: self.current.windows)
                }
                self.onAdd?()
                await Task.yield()
                return DesktopSnapshot(displays: self.current.displays, windows: [])
            }, placeOrdinaryDesktop: { step, expected in
                XCTAssertEqual(expected.displays, self.current.displays)
                self.placements.append(step)
                self.operations.append("place:\(step.spaceID)")
                if self.placeFailureAt == self.placements.count {
                    throw NSError(domain: "ManualMissionControlClose", code: 1)
                }
                if !self.placeNoOp {
                    let selected = self.current.displays.flatMap(\.spaces).first { $0.id == step.spaceID }!
                    let target = self.current.displays.first { $0.id == step.targetDisplayID }!
                    self.current = DesktopSnapshot(displays: self.current.displays.map { display in
                        var spaces = display.spaces.filter { $0.id != step.spaceID }
                        if display.id == step.targetDisplayID { spaces.insert(selected, at: step.targetIndex) }
                        return DisplaySnapshot(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame, spaces: spaces)
                    }, windows: self.current.windows.map { window in
                        guard window.spaceIDs == [step.spaceID] else { return window }
                        return WindowSnapshot(identity: window.identity, title: window.title,
                            frame: .init(x: target.frame.x + 20, y: target.frame.y + 20, width: window.frame.width, height: window.frame.height), spaceIDs: window.spaceIDs)
                    })
                }
                self.onPlace?()
                await Task.yield()
                return DesktopSnapshot(displays: self.current.displays, windows: [])
            }, finish: {
                self.finishCount += 1
                await self.onFinishAsync?()
                if self.finishFails { throw NSError(domain: "MissionControlCloseFailure", code: 1) }
            })
        }, loadDesktopRegistry: { profile in
            if let store = self.store { return try store.loadExternalDesktopRegistry(profile: profile) }
            return self.registry
        }, saveDesktopRegistry: { registry, profile in
            if let store = self.store { try store.saveExternalDesktopRegistry(registry, profile: profile); return }
            self.registry = registry
            self.registrySaveCount += 1
        }, pause: { _ in
            self.pauseCount += 1
            try Task.checkCancellation()
            await Task.yield()
        }, physicalDisplaysMatch: { reference in
            self.canConfirmPhysicalDisplays && reference.displays.count == self.current.displays.count &&
                reference.displays.allSatisfy { expected in
                    self.current.displays.contains {
                        $0.id == expected.id && $0.isBuiltIn == expected.isBuiltIn && $0.frame == expected.frame
                    }
                }
        }), automaticEnabled: automatic)
    }

    static func snapshot(external: Bool = false, space: UInt64 = 1) -> DesktopSnapshot {
        let builtIn = DisplaySnapshot(id: "builtin", isBuiltIn: true, frame: .init(x: 0, y: 0, width: 1000, height: 800), spaces: [1, 2, 3].map { SpaceSnapshot(id: $0, kind: .ordinary) })
        let monitor = DisplaySnapshot(id: "monitor", isBuiltIn: false, frame: .init(x: 1000, y: 0, width: 1000, height: 800), spaces: [10, 11, 12].map { SpaceSnapshot(id: $0, kind: .ordinary) })
        let windows: [WindowSnapshot] = (1...2).map { index in
            let identity = WindowIdentity(process: .init(pid: Int32(index), launchDate: Date(timeIntervalSince1970: 100)), windowID: UInt32(index), bundleIdentifier: "test.app\(index)")
            let onMonitor = external && index == 2
            let frame = WindowFrame(x: onMonitor ? 1020 : 20, y: 20, width: 100, height: 100)
            return WindowSnapshot(identity: identity, title: "private title", frame: frame, spaceIDs: [onMonitor ? space + 9 : space])
        }
        return DesktopSnapshot(displays: external ? [builtIn, monitor] : [builtIn], windows: windows)
    }

    static func threeExternalDesktops(reconnected: Bool = false, firstID: UInt64 = 100) -> DesktopSnapshot {
        let original = snapshot(external: true)
        let builtIn = DisplaySnapshot(id: "builtin", isBuiltIn: true, frame: original.displays[0].frame,
            spaces: (reconnected ? [1, 2, 3, 10, 11, 12] : [1, 2, 3]).map { SpaceSnapshot(id: $0, kind: .ordinary) })
        let monitor = DisplaySnapshot(id: "monitor", isBuiltIn: false, frame: original.displays[1].frame,
            spaces: (reconnected ? [firstID] : [10, 11, 12]).map { SpaceSnapshot(id: $0, kind: .ordinary) })
        let windows = (1...3).map { index in
            WindowSnapshot(identity: .init(process: .init(pid: Int32(index), launchDate: Date(timeIntervalSince1970: 100)), windowID: UInt32(index), bundleIdentifier: "test.app\(index)"),
                title: "unsaved text", frame: .init(x: reconnected ? 20 : 1020, y: 20, width: 100, height: 100),
                spaceIDs: [reconnected ? 1 : UInt64(index + 9)])
        }
        return DesktopSnapshot(displays: [builtIn, monitor], windows: windows)
    }

    static func originalDesktops(migrated: Bool = false, reordered: Bool = false, stableUUIDs: Bool = true,
                                 monitorID: String = "monitor", spaceOffset: UInt64 = 0, monitorName: String? = nil) -> DesktopSnapshot {
        let state = threeExternalDesktops()
        func remapped(_ id: UInt64) -> UInt64 { id >= 10 ? id + spaceOffset : id }
        func space(_ id: UInt64) -> SpaceSnapshot {
            SpaceSnapshot(id: remapped(id), kind: .ordinary,
                stableUUID: stableUUIDs ? UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", remapped(id))) : nil)
        }
        let builtIn = DisplaySnapshot(id: "builtin", isBuiltIn: true, frame: state.displays[0].frame,
            spaces: (migrated ? [1, 2, 3, 10, 11, 12] : [1, 2, 3]).map(space))
        let monitor = DisplaySnapshot(id: monitorID, isBuiltIn: false, frame: state.displays[1].frame,
            spaces: (migrated ? [100] : (reordered ? [12, 10, 11] : [10, 11, 12])).map(space), localizedName: monitorName)
        var windows = state.windows.map { window in
            WindowSnapshot(identity: window.identity, title: window.title,
                frame: .init(x: migrated ? 20 : 1020, y: 20, width: 100, height: 100), spaceIDs: window.spaceIDs.map(remapped))
        }
        if migrated {
            windows.append(WindowSnapshot(identity: .init(process: .init(pid: 99, launchDate: Date(timeIntervalSince1970: 99)), windowID: 99, bundleIdentifier: "unmanaged.app"),
                title: "unmanaged unsaved document", frame: .init(x: 20, y: 20, width: 120, height: 150), spaceIDs: [remapped(11)]))
        }
        return DesktopSnapshot(displays: [builtIn, monitor], windows: windows)
    }
}
