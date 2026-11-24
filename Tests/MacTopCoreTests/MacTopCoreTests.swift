import Foundation
import XCTest
@testable import MacTopCore

final class MacTopCoreTests: XCTestCase {
    private let builtInFrame = WindowFrame(x: 0, y: 0, width: 1000, height: 800)
    private let externalFrame = WindowFrame(x: 1000, y: 0, width: 1600, height: 1000)

    private func identity(_ id: UInt32 = 7, pid: Int32 = 40, launch: TimeInterval = 100, bundle: String = "test.editor") -> WindowIdentity {
        WindowIdentity(process: ProcessIdentity(pid: pid, launchDate: Date(timeIntervalSince1970: launch)), windowID: id, bundleIdentifier: bundle)
    }

    private func window(_ id: WindowIdentity? = nil, space: UInt64 = 1, external: Bool = false, spaces: [UInt64]? = nil, issue: String? = nil) -> WindowSnapshot {
        WindowSnapshot(identity: id ?? identity(), title: "Private document", frame: WindowFrame(x: external ? 1100 : 100, y: 100, width: 500, height: 400), spaceIDs: spaces ?? [space], verificationIssue: issue)
    }

    private func snapshot(windows: [WindowSnapshot] = [], external: Bool = true, externalID: String = "monitor-A", reversed: Bool = false, externalSpaces: [SpaceSnapshot]? = nil, complete: Bool = true, permission: Bool = true) -> DesktopSnapshot {
        var displays = [DisplaySnapshot(id: "built-in", isBuiltIn: true, frame: builtInFrame, spaces: [SpaceSnapshot(id: 1, kind: .ordinary), SpaceSnapshot(id: 2, kind: .ordinary)])]
        if external {
            displays.append(DisplaySnapshot(id: externalID, isBuiltIn: false, frame: externalFrame, spaces: externalSpaces ?? [SpaceSnapshot(id: 10, kind: .ordinary), SpaceSnapshot(id: 11, kind: .ordinary), SpaceSnapshot(id: 12, kind: .ordinary)]))
        }
        return DesktopSnapshot(displays: reversed ? displays.reversed() : displays, windows: windows, hasAccessibilityPermission: permission, isComplete: complete)
    }

    func testCaptureKeepsEmptySpaceSequenceAndUsesDisplayIdentityRatherThanEnumeration() throws {
        let modes = [SpaceSnapshot(id: 10, kind: .ordinary), SpaceSnapshot(id: 11, kind: .fullScreen), SpaceSnapshot(id: 12, kind: .ordinary)]
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 12, external: true)], reversed: true, externalSpaces: modes))
        XCTAssertEqual(profile.topology, .external(displayID: "monitor-A"))
        XCTAssertEqual(profile.displays.first?.spaces, [.ordinary, .fullScreen, .ordinary])
        XCTAssertEqual(profile.windows.first?.destination, WindowDestination(display: .external(id: "monitor-A"), spaceIndex: 2, kind: .ordinary))
        let plan = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(space: 12, external: true)], externalSpaces: modes))
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.alreadyCorrect, 1)
    }

    func testRestoresByCurrentSpacePositionAndLeavesUnmanagedWindowAlone() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 12, external: true)]))
        let spaces = [SpaceSnapshot(id: 20, kind: .ordinary), SpaceSnapshot(id: 21, kind: .ordinary), SpaceSnapshot(id: 22, kind: .ordinary)]
        let state = snapshot(windows: [window(), window(identity(99, bundle: "unrelated.app"))], reversed: true, externalSpaces: spaces)
        let plan = RestorationPlanner.plan(profile: profile, snapshot: state)
        XCTAssertEqual(plan.moves, [WindowMove(identity: identity(), displayID: "monitor-A", spaceID: 22)])
        XCTAssertTrue(plan.pending.isEmpty)
        XCTAssertTrue(plan.issues.isEmpty)
    }

    func testExclusiveMembershipAndPhysicalGeometryAreBothRequiredForVerification() throws {
        let move = WindowMove(identity: identity(), displayID: "monitor-A", spaceID: 12)
        XCTAssertFalse(RestorationPlanner.isRestored(move: move, snapshot: snapshot(windows: [window(space: 12)])))
        XCTAssertFalse(RestorationPlanner.isRestored(move: move, snapshot: snapshot(windows: [window(space: 12, external: true, spaces: [11, 12])])))
        XCTAssertTrue(RestorationPlanner.isRestored(move: move, snapshot: snapshot(windows: [window(space: 12, external: true)])))
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 12, external: true)]))
        XCTAssertEqual(RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(space: 12)])).moves, [move])
    }

    func testSecondApplicationIsIdempotent() throws {
        let intended = snapshot(windows: [window(space: 11, external: true)])
        let profile = try LayoutProfile.capture(snapshot: intended)
        XCTAssertEqual(RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window()])).moves.count, 1)
        let second = RestorationPlanner.plan(profile: profile, snapshot: intended)
        XCTAssertEqual(second.moves.count, 0)
        XCTAssertEqual(second.alreadyCorrect, 1)
        XCTAssertTrue(second.isComplete)
    }

    func testRestartFallbackRequiresOnePendingWindowAndOneCandidate() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 10, external: true)]))
        let restarted = identity(8, pid: 40, launch: 200)
        let plan = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(restarted)]))
        XCTAssertEqual(plan.moves.first?.identity, restarted, "Reused PID must be disambiguated by launch date")
        XCTAssertEqual(plan.moves.first?.savedIdentity, profile.windows[0].identity)
        let ambiguous = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(restarted), window(identity(9, pid: 50, launch: 200))]))
        XCTAssertTrue(ambiguous.moves.isEmpty)
        XCTAssertEqual(ambiguous.pending.first?.reason, .ambiguousWindow)
    }

    func testTwoUnmatchedSavedWindowsDoNotGuessAfterRestart() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 10, external: true), window(identity(8), space: 11, external: true)]))
        let plan = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(identity(90, pid: 50, launch: 200))]))
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.pending.map(\.reason), [.ambiguousWindow, .ambiguousWindow])
    }

    func testSameProcessNewWindowIsNotMistakenForClosedSavedWindow() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 10, external: true)]))
        let plan = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(identity(8))]))
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.pending.first?.reason, .windowUnavailable)
    }

    func testExactIdentityIsReservedBeforeFallbackAndClosedAppIsPending() throws {
        let old = window(space: 10, external: true)
        let second = window(identity(8, pid: 50, launch: 200), space: 11, external: true)
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [old, second]))
        let plan = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: [window(identity(8, pid: 50, launch: 200))]))
        XCTAssertEqual(plan.moves.map(\.identity), [second.identity])
        XCTAssertEqual(plan.pending.first?.identity, old.identity)
        XCTAssertEqual(plan.pending.first?.reason, .ambiguousWindow)
        let closed = RestorationPlanner.plan(profile: profile, snapshot: snapshot())
        XCTAssertEqual(closed.pending.map(\.reason), [.applicationClosed, .applicationClosed])
    }

    func testStickyAndUnsupportedWindowsStayPendingWithoutChangingOtherWindows() throws {
        let modes = [SpaceSnapshot(id: 10, kind: .ordinary), SpaceSnapshot(id: 11, kind: .fullScreen), SpaceSnapshot(id: 12, kind: .splitView)]
        let windows = [window(spaces: [1, 2]), window(identity(8), space: 11, external: true), window(identity(9), space: 12, external: true), window(identity(10), issue: "AX role unknown"), window(identity(11))]
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: windows, externalSpaces: modes))
        let plan = RestorationPlanner.plan(profile: profile, snapshot: snapshot(windows: windows, externalSpaces: modes))
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.pending.map(\.reason), [.nonExclusiveMembership, .unsupportedSpaceKind, .unsupportedSpaceKind, .unverifiedWindow])
        XCTAssertEqual(profile.displays.last?.spaces, [.ordinary, .fullScreen, .splitView])
    }

    func testCaptureWithOnlyUnverifiableWindowsCannotReplaceAUsefulProfile() throws {
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: snapshot(windows: [window(issue: "AX unavailable")])))
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 12)])))
        XCTAssertNoThrow(try LayoutProfile.capture(snapshot: snapshot()), "A complete genuinely empty desktop may be intentionally captured")
    }

    func testDisplayOnlySnapshotCannotCaptureOrPlanAnEmptyWindowInventory() throws {
        let complete = snapshot()
        let displaysOnly = DesktopSnapshot(displays: complete.displays, windows: [], includesWindowInventory: false)
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: displaysOnly))
        let profile = try LayoutProfile.capture(snapshot: complete)
        let plan = RestorationPlanner.plan(profile: profile, snapshot: displaysOnly)
        XCTAssertFalse(plan.isComplete)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertFalse(plan.issues.isEmpty)
        XCTAssertTrue(RestorationPlanner.plan(profile: profile, snapshot: complete).isComplete)
    }

    func testSnapshotCodableKeepsOldInventoriesAndRejectsEncodedOmittedInventory() throws {
        let complete = snapshot()
        let encoded = try JSONEncoder().encode(complete)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["windowInventoryOmitted"], "Full snapshots keep the previous representation")
        let decoded = try JSONDecoder().decode(DesktopSnapshot.self, from: encoded)
        XCTAssertNoThrow(try LayoutProfile.capture(snapshot: decoded))

        let displaysOnly = DesktopSnapshot(displays: complete.displays, windows: [], includesWindowInventory: false)
        let decodedPartial = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(displaysOnly))
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: decodedPartial))
    }

    func testMissingDestinationAndEmptySpacesAreReported() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 12, external: true)]))
        let shortState = snapshot(windows: [window()], externalSpaces: [SpaceSnapshot(id: 10, kind: .ordinary)])
        let plan = RestorationPlanner.plan(profile: profile, snapshot: shortState)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.pending.first?.reason, .destinationMissing)
        XCTAssertEqual(plan.issues.count, 2)
        let emptyProfile = try LayoutProfile.capture(snapshot: snapshot())
        let emptyPlan = RestorationPlanner.plan(profile: emptyProfile, snapshot: shortState)
        XCTAssertEqual(emptyPlan.issues.count, 2, "Empty desktops are part of the saved layout")
        XCTAssertFalse(emptyPlan.isComplete)
    }

    func testMissingPermissionIncompleteInventoryAndUnknownMonitorCannotAct() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(windows: [window()]))
        for state in [snapshot(complete: false), snapshot(permission: false)] {
            XCTAssertThrowsError(try LayoutProfile.capture(snapshot: state))
            let plan = RestorationPlanner.plan(profile: profile, snapshot: state)
            XCTAssertTrue(plan.moves.isEmpty)
            XCTAssertFalse(plan.issues.isEmpty)
        }
        let unknown = RestorationPlanner.plan(profile: profile, snapshot: snapshot(externalID: "monitor-B"))
        XCTAssertTrue(unknown.moves.isEmpty)
        XCTAssertFalse(unknown.issues.isEmpty)
    }

    func testUnsupportedTopologyAndDuplicateInventoryAreRejected() throws {
        let externalOnly = DesktopSnapshot(displays: [DisplaySnapshot(id: "external", isBuiltIn: false, frame: externalFrame, spaces: [SpaceSnapshot(id: 10, kind: .ordinary)])], windows: [])
        XCTAssertThrowsError(try externalOnly.topology())
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: externalOnly))
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: snapshot(windows: [window(), window()])))
        let duplicateSpace = snapshot(externalSpaces: [SpaceSnapshot(id: 1, kind: .ordinary)])
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: duplicateSpace))
    }

    func testStorePersistsTwoIndependentProfilesAndRejectsAnotherExternalMonitor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let portable = try LayoutProfile.capture(snapshot: snapshot(windows: [window()], external: false))
        let external = try LayoutProfile.capture(snapshot: snapshot(windows: [window(space: 12, external: true)]))
        XCTAssertNil(try store.load(.portable))
        try store.save(portable)
        try store.save(external)
        let restartedStore = ProfileStore(directory: directory)
        XCTAssertEqual(try restartedStore.load(.portable), portable)
        XCTAssertEqual(try restartedStore.load(.external(displayID: "monitor-A")), external)
        let another = try LayoutProfile.capture(snapshot: snapshot(externalID: "monitor-B"))
        XCTAssertThrowsError(try store.save(another))
        XCTAssertEqual(try store.load(.external(displayID: "monitor-A")), external)
        let updatedPortable = try LayoutProfile.capture(snapshot: snapshot(external: false))
        try store.save(updatedPortable)
        XCTAssertEqual(try store.load(.portable), updatedPortable)
        XCTAssertEqual(try store.load(.external(displayID: "monitor-A")), external)
    }

    func testRejectedSaveAndCorruptFilePreserveExistingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let valid = try LayoutProfile.capture(snapshot: snapshot(external: false))
        try store.save(valid)
        let url = directory.appendingPathComponent("macbook.json")
        let before = try Data(contentsOf: url)
        let invalid = LayoutProfile(schemaVersion: 999, topology: valid.topology, displays: valid.displays, windows: valid.windows)
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let corrupt = Data("broken profile".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.save(valid))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testFilesystemWriteFailureDoesNotChangeOtherValidProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let portable = try LayoutProfile.capture(snapshot: snapshot(external: false))
        try store.save(portable)
        let portableBytes = try Data(contentsOf: directory.appendingPathComponent("macbook.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("macbook-external.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(LayoutProfile.capture(snapshot: snapshot())))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("macbook.json")), portableBytes)
    }
}
