import XCTest
@testable import MacTopCore

final class OrdinaryDesktopAdditionTests: XCTestCase {
    private func snapshot(external: [SpaceSnapshot], builtIn: [SpaceSnapshot] = [.init(id: 1, kind: .ordinary)], windows: [WindowSnapshot] = []) -> DesktopSnapshot {
        DesktopSnapshot(displays: [
            DisplaySnapshot(id: "builtin", isBuiltIn: true, frame: .init(x: 0, y: 0, width: 1000, height: 800), spaces: builtIn),
            DisplaySnapshot(id: "monitor", isBuiltIn: false, frame: .init(x: 1000, y: 0, width: 1000, height: 800), spaces: external)
        ], windows: windows)
    }

    private func ordinary(_ ids: [UInt64]) -> [SpaceSnapshot] { ids.map { .init(id: $0, kind: .ordinary) } }

    func testDeficitIncludesSavedEmptyDesktopsWithoutChangingProfileSchema() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(external: ordinary([10, 11, 12])))
        let current = snapshot(external: ordinary([100]))
        XCTAssertEqual(try OrdinaryDesktopAddition.missingCount(profile: profile, snapshot: current), 2)
        XCTAssertEqual(profile.schemaVersion, 1)
        XCTAssertEqual(try OrdinaryDesktopAddition.missingCount(profile: profile, snapshot: snapshot(external: ordinary([100, 101, 102, 103]))), 0)
    }

    func testOnlyOneOrdinaryAdditionAtEndIsAccepted() throws {
        let before = snapshot(external: ordinary([100]))
        XCTAssertFalse(try OrdinaryDesktopAddition.isVerified(before: before, after: before, displayID: "monitor"))
        XCTAssertTrue(try OrdinaryDesktopAddition.isVerified(before: before, after: snapshot(external: ordinary([100, 101])), displayID: "monitor"))
        for external in [ordinary([101, 100]), ordinary([100, 101, 102]), ordinary([101]), [.init(id: 100, kind: .ordinary), .init(id: 101, kind: .fullScreen)], ordinary([100, 1])] {
            XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: before, after: snapshot(external: external), displayID: "monitor"))
        }
        XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: before,
            after: snapshot(external: ordinary([100]), builtIn: ordinary([1, 2])), displayID: "monitor"))
    }

    func testPreservesEveryExistingIDKindFrameAndDisplayIdentity() throws {
        let before = snapshot(external: ordinary([100]), builtIn: [.init(id: 1, kind: .ordinary), .init(id: 2, kind: .fullScreen)])
        let valid = snapshot(external: ordinary([100, 101]), builtIn: before.displays[0].spaces)
        XCTAssertTrue(try OrdinaryDesktopAddition.isVerified(before: before, after: valid, displayID: "monitor"))
        for changed in [
            snapshot(external: ordinary([100, 101]), builtIn: ordinary([1, 2])),
            snapshot(external: ordinary([100, 101]), builtIn: [.init(id: 1, kind: .ordinary), .init(id: 3, kind: .fullScreen)]),
            DesktopSnapshot(displays: [valid.displays[0]], windows: []),
            DesktopSnapshot(displays: valid.displays.map { .init(id: $0.id, isBuiltIn: $0.isBuiltIn, frame: .init(x: $0.frame.x + 1, y: 0, width: 1000, height: 800), spaces: $0.spaces) }, windows: [])
        ] {
            XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: before, after: changed, displayID: "monitor"))
        }
    }

    func testWindowInventoryIsIndependentOfDisplayDelta() throws {
        let before = snapshot(external: ordinary([100]))
        let identity = WindowIdentity(process: .init(pid: 1, launchDate: Date()), windowID: 1, bundleIdentifier: "another.app")
        let window = WindowSnapshot(identity: identity, title: "new unsaved work", frame: .init(x: 10, y: 10, width: 100, height: 100), spaceIDs: [1])
        XCTAssertTrue(try OrdinaryDesktopAddition.isVerified(before: before,
            after: snapshot(external: ordinary([100, 101]), windows: [window]), displayID: "monitor"))
    }

    func testInvalidInventoriesAndBuiltInCreationAreRejectedEvenWhenUnchanged() throws {
        let valid = snapshot(external: ordinary([100]))
        for invalid in [
            snapshot(external: [.init(id: 100, kind: .fullScreen)]),
            snapshot(external: [.init(id: 100, kind: .unknown)]),
            snapshot(external: ordinary([1])),
            DesktopSnapshot(displays: valid.displays, windows: [], hasAccessibilityPermission: false),
            DesktopSnapshot(displays: valid.displays, windows: [], isComplete: false)
        ] {
            XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: invalid, after: invalid, displayID: "monitor"))
        }
        XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: valid, after: valid, displayID: "builtin"))
        XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: valid, after: valid, displayID: "unknown"))
    }

    func testUnsupportedModesNeverRequestCreationAndCurrentExtraDesktopsRemain() throws {
        let ordinaryProfile = try LayoutProfile.capture(snapshot: snapshot(external: ordinary([10, 11, 12])))
        XCTAssertEqual(try OrdinaryDesktopAddition.missingCount(profile: ordinaryProfile,
            snapshot: snapshot(external: [.init(id: 100, kind: .fullScreen)])), 0)
        let mixedProfile = try LayoutProfile.capture(snapshot: snapshot(external: [.init(id: 10, kind: .ordinary), .init(id: 11, kind: .fullScreen), .init(id: 12, kind: .ordinary)]))
        XCTAssertEqual(try OrdinaryDesktopAddition.missingCount(profile: mixedProfile, snapshot: snapshot(external: ordinary([100]))), 0)
    }

    func testLimitIsPerExternalDisplayAndAccumulatedBuiltInSpacesAreNeverRemoved() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot(external: ordinary([10, 11, 12])))
        let accumulated = snapshot(external: ordinary([100]), builtIn: ordinary(Array(1...20)))
        XCTAssertEqual(try OrdinaryDesktopAddition.missingCount(profile: profile, snapshot: accumulated), 2)
        let tooMany = try LayoutProfile.capture(snapshot: snapshot(external: ordinary(Array(100...116))))
        XCTAssertThrowsError(try OrdinaryDesktopAddition.missingCount(profile: tooMany, snapshot: accumulated))
        let atLimit = try LayoutProfile.capture(snapshot: snapshot(external: ordinary(Array(100...115))))
        XCTAssertEqual(try OrdinaryDesktopAddition.missingCount(profile: atLimit, snapshot: accumulated), 15)
    }
}
