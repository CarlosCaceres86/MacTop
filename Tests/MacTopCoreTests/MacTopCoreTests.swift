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
        XCTAssertEqual(try externalOnly.topology(), .extended(builtIn: false, externalDisplayIDs: ["external"]))
        XCTAssertNoThrow(try LayoutProfile.capture(snapshot: externalOnly))
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: snapshot(windows: [window(), window()])))
        let duplicateSpace = snapshot(externalSpaces: [SpaceSnapshot(id: 1, kind: .ordinary)])
        XCTAssertThrowsError(try LayoutProfile.capture(snapshot: duplicateSpace))
    }

    func testExactDisplaySetsAndCanonicalValidation() throws {
        let base = snapshot()
        let b = DisplaySnapshot(id: "monitor-B", isBuiltIn: false, frame: externalFrame, spaces: [.init(id: 20, kind: .ordinary)])
        let c = DisplaySnapshot(id: "monitor-C", isBuiltIn: false, frame: externalFrame, spaces: [.init(id: 30, kind: .ordinary)])
        let displays = base.displays + [b, c]
        let open = DesktopSnapshot(displays: displays, windows: [])
        let reverse = DesktopSnapshot(displays: displays.reversed(), windows: [])
        let closed = DesktopSnapshot(displays: Array(displays.dropFirst()), windows: [])
        let openTopology = try open.topology()
        XCTAssertEqual(openTopology, .extended(builtIn: true, externalDisplayIDs: ["monitor-A", "monitor-B", "monitor-C"]))
        XCTAssertEqual(try reverse.topology(), openTopology)
        XCTAssertNotEqual(try closed.topology(), openTopology)
        XCTAssertEqual(openTopology.displayRoles, [.builtIn, .external(id: "monitor-A"), .external(id: "monitor-B"), .external(id: "monitor-C")])
        XCTAssertTrue(openTopology.hasExternalDisplays)
        XCTAssertFalse(ProfileTopology.portable.hasExternalDisplays)
        XCTAssertNoThrow(try LayoutProfile.capture(snapshot: closed))
        XCTAssertThrowsError(try DesktopSnapshot(displays: [], windows: []).topology())
        XCTAssertThrowsError(try DesktopSnapshot(displays: [base.displays[0], base.displays[0]], windows: []).topology())
        let ambiguous = DisplaySnapshot(id: "MONITOR-A", isBuiltIn: false, frame: externalFrame, spaces: [.init(id: 40, kind: .ordinary)])
        XCTAssertThrowsError(try DesktopSnapshot(displays: base.displays + [ambiguous], windows: []).topology())
        let invalid: [ProfileTopology] = [.extended(builtIn: true, externalDisplayIDs: ["monitor-A"]),
            .extended(builtIn: false, externalDisplayIDs: []),
            .extended(builtIn: false, externalDisplayIDs: ["monitor-B", "monitor-A"]),
            .extended(builtIn: false, externalDisplayIDs: ["monitor-A", "MONITOR-A"])]
        for topology in invalid {
            XCTAssertThrowsError(try LayoutProfile(topology: topology, displays: [], windows: []).validate())
        }
    }

    func testExtendedProfilesAndDesktopRegistriesAreIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let original = try LayoutProfile.capture(snapshot: snapshot())
        try store.save(original)
        let originalRegistry = try ExternalDesktopRegistry(profile: original)
        try store.saveExternalDesktopRegistry(originalRegistry, profile: original)
        let oldFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let oldBytes = try oldFiles.map { try Data(contentsOf: $0) }
        let extra = DisplaySnapshot(id: "monitor-B", isBuiltIn: false, frame: externalFrame, spaces: [.init(id: 20, kind: .ordinary)])
        let other = DisplaySnapshot(id: "monitor-C", isBuiltIn: false, frame: externalFrame, spaces: [.init(id: 30, kind: .ordinary)])
        let open = try LayoutProfile.capture(snapshot: DesktopSnapshot(displays: snapshot().displays + [extra], windows: []))
        let closed = try LayoutProfile.capture(snapshot: DesktopSnapshot(displays: Array(snapshot().displays.dropFirst()) + [extra], windows: []))
        let sameCount = try LayoutProfile.capture(snapshot: DesktopSnapshot(displays: snapshot().displays + [other], windows: []))
        for profile in [open, closed, sameCount] { try store.save(profile) }
        let builtInRegistry = try ExternalDesktopRegistry(profile: open, role: .builtIn)
        let firstRegistry = try ExternalDesktopRegistry(profile: open, role: .external(id: "monitor-A"))
        let secondRegistry = try ExternalDesktopRegistry(profile: open, role: .external(id: "monitor-B"))
        for registry in [builtInRegistry, firstRegistry, secondRegistry] { try store.saveDesktopRegistry(registry, profile: open) }
        XCTAssertEqual(try store.load(open.topology), open)
        XCTAssertEqual(try store.load(closed.topology), closed)
        XCTAssertEqual(try store.load(sameCount.topology), sameCount)
        XCTAssertEqual(try store.loadDesktopRegistry(profile: open, role: .builtIn), builtInRegistry)
        XCTAssertEqual(try store.loadDesktopRegistry(profile: open, role: .external(id: "monitor-A")), firstRegistry)
        XCTAssertEqual(try store.loadDesktopRegistry(profile: open, role: .external(id: "monitor-B")), secondRegistry)
        XCTAssertNil(try store.loadDesktopRegistry(profile: closed, role: .external(id: "monitor-A")))
        XCTAssertNil(try store.loadDesktopRegistry(profile: original, role: .builtIn))
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: original), originalRegistry)
        for (url, bytes) in zip(oldFiles, oldBytes) { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        let originalBuiltIn = try ExternalDesktopRegistry(profile: original, role: .builtIn)
        try store.saveDesktopRegistry(originalBuiltIn, profile: original)
        XCTAssertEqual(try store.loadDesktopRegistry(profile: original, role: .builtIn), originalBuiltIn)
        XCTAssertEqual(try store.loadDesktopRegistry(profile: open, role: .builtIn), builtInRegistry)
        let newCapture = LayoutProfile(capturedAt: open.capturedAt.addingTimeInterval(1), topology: open.topology, displays: open.displays, windows: open.windows)
        XCTAssertNil(try store.loadDesktopRegistry(profile: newCapture, role: .builtIn))
    }

    func testStorePersistsIndependentMonitorProfilesAndRegistries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let portable = try LayoutProfile.capture(snapshot: snapshot(windows: [window()], external: false))
        let homeSnapshot = snapshot(windows: [window(space: 12, external: true)])
        let home = try LayoutProfile.capture(snapshot: homeSnapshot)
        let officeSnapshot = snapshot(externalID: "monitor-B")
        let office = try LayoutProfile.capture(snapshot: officeSnapshot)
        let session = UUID()
        let homeRegistry = try ExternalDesktopRegistry(profile: home, snapshot: homeSnapshot, sessionID: session)
        let officeRegistry = try ExternalDesktopRegistry(profile: office, snapshot: officeSnapshot, sessionID: session)
        XCTAssertNil(try store.load(.portable))
        try store.save(portable)
        try store.save(home)
        try store.saveExternalDesktopRegistry(homeRegistry, profile: home)
        XCTAssertNil(try store.load(office.topology))
        try store.save(office)
        try store.saveExternalDesktopRegistry(officeRegistry, profile: office)
        let restartedStore = ProfileStore(directory: directory)
        XCTAssertEqual(try restartedStore.load(.portable), portable)
        XCTAssertEqual(try restartedStore.load(home.topology), home)
        XCTAssertEqual(try restartedStore.loadExternalDesktopRegistry(profile: home), homeRegistry)
        XCTAssertEqual(try restartedStore.load(office.topology), office)
        XCTAssertEqual(try restartedStore.loadExternalDesktopRegistry(profile: office), officeRegistry)

        let updatedOfficeSnapshot = snapshot(externalID: "monitor-B", externalSpaces: [.init(id: 101, kind: .ordinary)])
        let updatedOffice = try LayoutProfile.capture(snapshot: updatedOfficeSnapshot)
        let updatedOfficeRegistry = try ExternalDesktopRegistry(profile: updatedOffice, snapshot: updatedOfficeSnapshot, sessionID: session)
        try restartedStore.save(updatedOffice)
        // If writing the registry is interrupted, the earlier capture's identities do not apply.
        XCTAssertEqual(try store.load(office.topology), updatedOffice)
        XCTAssertNil(try store.loadExternalDesktopRegistry(profile: updatedOffice))
        try restartedStore.saveExternalDesktopRegistry(updatedOfficeRegistry, profile: updatedOffice)
        XCTAssertEqual(try store.load(home.topology), home)
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: home), homeRegistry)
        XCTAssertEqual(try store.load(office.topology), updatedOffice)
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: updatedOffice), updatedOfficeRegistry)
        XCTAssertNil(try store.loadExternalDesktopRegistry(profile: office))
        XCTAssertEqual(try store.load(.portable), portable)
    }

    func testLegacyExternalProfileAndDesktopIdentitiesStayWithTheirMonitor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let homeSnapshot = snapshot(windows: [window(space: 12, external: true)])
        let home = try LayoutProfile.capture(snapshot: homeSnapshot)
        let legacyRegistry = try ExternalDesktopRegistry(profile: home, snapshot: homeSnapshot, sessionID: UUID())
        let legacyProfileURL = directory.appendingPathComponent("macbook-external.json")
        let legacyRegistryURL = directory.appendingPathComponent("external-desktop-identities.json")
        let profileBytes = try JSONEncoder().encode(home)
        let registryBytes = try JSONEncoder().encode(legacyRegistry)
        try profileBytes.write(to: legacyProfileURL)
        try registryBytes.write(to: legacyRegistryURL)

        let office = try LayoutProfile.capture(snapshot: snapshot(externalID: "monitor-B"))
        XCTAssertEqual(try store.load(home.topology), home)
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: home), legacyRegistry)
        XCTAssertNil(try store.load(office.topology))
        XCTAssertNil(try store.loadExternalDesktopRegistry(profile: office))
        try store.save(office)
        XCTAssertNil(try store.loadExternalDesktopRegistry(profile: office))
        try store.saveExternalDesktopRegistry(ExternalDesktopRegistry(profile: office), profile: office)

        let updatedHomeRegistry = try ExternalDesktopRegistry(profile: home, snapshot: homeSnapshot, sessionID: UUID())
        try store.saveExternalDesktopRegistry(updatedHomeRegistry, profile: home)
        let reopened = ProfileStore(directory: directory)
        XCTAssertEqual(try reopened.load(home.topology), home)
        XCTAssertEqual(try reopened.loadExternalDesktopRegistry(profile: home), updatedHomeRegistry)
        XCTAssertEqual(try reopened.load(office.topology), office)
        XCTAssertEqual(try Data(contentsOf: legacyProfileURL), profileBytes)
        XCTAssertEqual(try Data(contentsOf: legacyRegistryURL), registryBytes)
    }

    func testScopedProfileTakesPrecedenceAndSavingAnotherMonitorPreservesCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let legacy = try LayoutProfile.capture(snapshot: snapshot())
        let updated = try LayoutProfile.capture(snapshot: snapshot(externalSpaces: [.init(id: 99, kind: .ordinary)]))
        let legacyURL = directory.appendingPathComponent("macbook-external.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        try store.save(updated)
        XCTAssertEqual(try store.load(legacy.topology), updated)

        let scopedURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent != legacyURL.lastPathComponent })
        let corruptScoped = Data("invalid scoped profile".utf8)
        try corruptScoped.write(to: scopedURL)
        XCTAssertThrowsError(try store.load(legacy.topology))
        XCTAssertThrowsError(try store.save(updated))

        let corruptLegacy = Data("invalid legacy profile".utf8)
        try corruptLegacy.write(to: legacyURL)
        let office = try LayoutProfile.capture(snapshot: snapshot(externalID: "monitor-B"))
        try store.save(office)
        XCTAssertEqual(try store.load(office.topology), office)
        XCTAssertEqual(try Data(contentsOf: scopedURL), corruptScoped)
        XCTAssertEqual(try Data(contentsOf: legacyURL), corruptLegacy)
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
        let external = try LayoutProfile.capture(snapshot: snapshot())
        try store.save(external)
        let externalURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent != "macbook.json" })
        try FileManager.default.removeItem(at: externalURL)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(external))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("macbook.json")), portableBytes)
    }
}
