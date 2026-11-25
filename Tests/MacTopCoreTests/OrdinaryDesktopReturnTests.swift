import XCTest
@testable import MacTopCore

final class OrdinaryDesktopReturnTests: XCTestCase {
    let session = UUID()
    let a = UUID(), b = UUID(), c = UUID(), placeholder = UUID()
    func space(_ id: UInt64, _ uuid: UUID? = nil) -> SpaceSnapshot { .init(id: id, kind: .ordinary, stableUUID: uuid) }
    func snapshot(_ external: [SpaceSnapshot], _ builtIn: [SpaceSnapshot], windows: [WindowSnapshot] = []) -> DesktopSnapshot {
        .init(displays: [
            .init(id: "builtin", isBuiltIn: true, frame: .init(x: 0, y: 0, width: 1000, height: 800), spaces: builtIn),
            .init(id: "monitor", isBuiltIn: false, frame: .init(x: 1000, y: 0, width: 1000, height: 800), spaces: external)
        ], windows: windows)
    }
    func testReturnsOriginalsBeforePlaceholderAndKeepsUnprofiledWindow() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a), space(11,b), space(12,c)], [space(1)]))
        let registry = try ExternalDesktopRegistry(profile: profile)
        let identity = WindowIdentity(process: .init(pid: 10, launchDate: Date()), windowID: 20, bundleIdentifier: "foreign")
        let foreign = WindowSnapshot(identity: identity, title: "unsaved outside profile", frame: .init(x: 20, y: 20, width: 100, height: 100), spaceIDs: [10])
        var current = snapshot([space(100,placeholder)], [space(1), space(10,a), space(11,b), space(12,c)], windows: [foreign])
        for (index, uuid) in [a,b,c].enumerated() {
            guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registry: registry, sessionID: session) else { return XCTFail("must return original") }
            XCTAssertEqual(step.stableUUID, uuid)
            XCTAssertEqual(step.targetIndex, index)
            let moving = current.displays[0].spaces.first { $0.id == step.spaceID }!
            var external = current.displays[1].spaces
            external.insert(moving, at: index)
            let next = snapshot(external, current.displays[0].spaces.filter { $0.id != step.spaceID }, windows: [foreign])
            XCTAssertTrue(try OrdinaryDesktopReturn.isVerified(before: current, after: next, step: step))
            current = next
        }
        XCTAssertEqual(current.displays[1].spaces.map(\.id), [10,11,12,100])
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registry: registry, sessionID: session), .ready)
        XCTAssertEqual(try OrdinaryDesktopReturn.extraDesktopCount(profile: profile, snapshot: current), 1)
    }
    func testV1CreatesOnlyDeficitAndDoesNotGuessOriginalFromWindowOrPosition() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10),space(11),space(12)], [space(1)]))
        var registry = try ExternalDesktopRegistry(profile: profile)
        let before = snapshot([space(100)], [space(1),space(10),space(11),space(12)])
        guard case .create(slot: 1, reason: _) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: before, registry: registry, sessionID: session) else { return XCTFail("only deficit") }
        let after = snapshot([space(100),space(101)], before.displays[0].spaces)
        try registry.recordCreated(before: before, after: after, slot: 1, sessionID: session)
        XCTAssertNil(registry.slots[0].stableUUID)
        XCTAssertThrowsError(try registry.recordCreated(before: after,
            after: snapshot([space(100),space(101),space(102)], before.displays[0].spaces), slot: 1, sessionID: session))
        XCTAssertEqual(registry.slots[1].sessionSpaceID, 101)
        guard case .create(slot: 2, reason: _) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: after, registry: registry, sessionID: session) else { return XCTFail("next deficit") }
        let moved = snapshot([space(100)], [space(1),space(101)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: moved, registry: registry, sessionID: session) else { return XCTFail("created identity retained") }
        XCTAssertEqual(step.spaceID, 101)
        guard case .create = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: moved, registry: registry, sessionID: UUID()) else { return XCTFail("session ID cannot survive restart") }
    }
    func testKnownOriginalAlreadyExternalIsOrderedWithEarlierOriginals() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a),space(11,b),space(12,c)], [space(1)]))
        let registry = try ExternalDesktopRegistry(profile: profile)
        let current = snapshot([space(12,c),space(100,placeholder),space(10,a)], [space(1),space(11,b)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registry: registry, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(step.spaceID, 10)
        XCTAssertEqual(step.sourceDisplayID, "monitor")
        XCTAssertTrue(try OrdinaryDesktopReturn.isVerified(before: current, after: snapshot([space(10,a),space(12,c),space(100,placeholder)], current.displays[0].spaces), step: step))
    }
    func testExactDeltaRejectsOtherChangesNoOpAndLastBuiltIn() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a)], [space(1)]))
        let registry = try ExternalDesktopRegistry(profile: profile)
        let before = snapshot([space(100)], [space(1),space(10,a),space(2)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: before, registry: registry, sessionID: session) else { return XCTFail() }
        XCTAssertFalse(try OrdinaryDesktopReturn.isVerified(before: before, after: before, step: step))
        for after in [snapshot([space(10,a),space(100)], [space(2),space(1)]),snapshot([space(10,a)], [space(1),space(2)]),snapshot([space(10,a),space(100),space(200)], [space(1),space(2)])] {
            XCTAssertThrowsError(try OrdinaryDesktopReturn.isVerified(before: before, after: after, step: step))
        }
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: snapshot([space(100)], [space(10,a)]), registry: registry, sessionID: session))
    }
    func testMissingUUIDFallsBackWithWarningAndDuplicateDoesNotCreate() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a)], [space(1)]))
        let registry = try ExternalDesktopRegistry(profile: profile)
        let missing = snapshot([space(100)], [space(1)])
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: missing, registry: registry, sessionID: session), .ready)
        XCTAssertFalse(try OrdinaryDesktopReturn.identityIssues(profile: profile, snapshot: missing, registry: registry, sessionID: session).isEmpty)
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: snapshot([space(100,a)], [space(1),space(10,a)]), registry: registry, sessionID: session))
    }
    func testProfileV1WithoutUUIDLoadsAndCaptureStoresOnlyUniqueUUID() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a),space(11,a),space(12,b)], [space(1)]))
        XCTAssertEqual(profile.displays[1].spaceUUIDs!, [nil,nil,b])
        let data = try JSONEncoder().encode(profile)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["displays"] = (json["displays"] as! [[String:Any]]).map { value in var result = value; result.removeValue(forKey: "spaceUUIDs"); return result }
        let old = try JSONDecoder().decode(LayoutProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.displays[1].spaceUUIDs)
    }
    func testNumericIDCannotOverrideKnownUUIDAndExplicitLiveIDsExpire() throws {
        let captured = snapshot([space(10,a),space(11)], [space(1)])
        let profile = try LayoutProfile.capture(snapshot: captured)
        let registry = try ExternalDesktopRegistry(profile: profile, snapshot: captured, sessionID: session)
        let reused = snapshot([space(100),space(101)], [space(1),space(10,b),space(11)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: reused, registry: registry, sessionID: session) else { return XCTFail("live non UUID ID should be recovered") }
        XCTAssertEqual(step.spaceID, 11)
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: reused, registry: registry, sessionID: UUID()), .ready)
    }
    func testAbsentSessionUUIDMustRemainAbsentToAuthorizeNumericIdentity() throws {
        let captured = snapshot([space(10),space(11)], [space(1)])
        let profile = try LayoutProfile.capture(snapshot: captured)
        var registry = try ExternalDesktopRegistry(profile: profile, snapshot: captured, sessionID: session)
        let sameIdentity = snapshot([space(100)], [space(1),space(11)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: sameIdentity, registry: registry, sessionID: session) else { return XCTFail("nil to nil remains valid in this instance") }
        XCTAssertEqual(step.spaceID, 11)

        let reusedIdentity = snapshot([space(100)], [space(1),space(11,b)])
        switch try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: reusedIdentity, registry: registry, sessionID: session) {
        case .create(slot: 1, reason: _): break
        default: XCTFail("a newly present UUID cannot match an ID observed without UUID")
        }
        let created = snapshot([space(100),space(200,c)], reusedIdentity.displays[0].spaces)
        XCTAssertNoThrow(try registry.recordCreated(before: reusedIdentity, after: created, slot: 1, sessionID: session))
        XCTAssertEqual(registry.slots[1].sessionSpaceID, 200)
    }

    func testReturnHonorsExternalCapacityLimit() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a)], [space(1)]))
        let registry = try ExternalDesktopRegistry(profile: profile)
        let full = snapshot((100...115).map { space(UInt64($0)) }, [space(1),space(10,a)])
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: full, registry: registry, sessionID: session))
    }
    func testReturnsLaterKnownBeforeCreatingUnknownGapThenConverges() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10),space(11),space(12,c)], [space(1)]))
        var registry = try ExternalDesktopRegistry(profile: profile)
        let before = snapshot([space(100)], [space(1),space(12,c)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: before, registry: registry, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(step.targetIndex, 1)
        let returned = snapshot([space(100),space(12,c)], [space(1)])
        XCTAssertTrue(try OrdinaryDesktopReturn.isVerified(before: before, after: returned, step: step))
        guard case .create(slot: 1, reason: _) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: returned, registry: registry, sessionID: session) else { return XCTFail() }
        let created = snapshot([space(100),space(12,c),space(200)], [space(1)])
        try registry.recordCreated(before: returned, after: created, slot: 1, sessionID: session)
        guard case let .move(order) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: created, registry: registry, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(order.spaceID, 200)
        let final = snapshot([space(100),space(200),space(12,c)], [space(1)])
        XCTAssertTrue(try OrdinaryDesktopReturn.isVerified(before: created, after: final, step: order))
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: final, registry: registry, sessionID: session), .ready)
    }
    func testRegistryRoundTripBoundToCaptureAndCorruptionIsNotAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let captured = snapshot([space(10,a),space(11)], [space(1)])
        let profile = try LayoutProfile.capture(snapshot: captured)
        XCTAssertNil(try store.loadExternalDesktopRegistry(profile: profile))
        let registry = try ExternalDesktopRegistry(profile: profile, snapshot: captured, sessionID: session)
        try store.saveExternalDesktopRegistry(registry, profile: profile)
        XCTAssertEqual(try store.loadExternalDesktopRegistry(profile: profile), registry)
        let newer = LayoutProfile(capturedAt: profile.capturedAt.addingTimeInterval(1), topology: profile.topology, displays: profile.displays, windows: profile.windows)
        XCTAssertNil(try store.loadExternalDesktopRegistry(profile: newer))
        let registryURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: registryURL)
        XCTAssertThrowsError(try store.loadExternalDesktopRegistry(profile: profile))
    }

    func testStructureComparisonAllowsActiveSpaceSwitchButDetectsOrderAndUUID() {
        let before = snapshot([space(10,a),space(11,b)], [space(1)])
        let switched = DesktopSnapshot(displays: before.displays.reversed().map { display in
            .init(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame, spaces: display.spaces, currentSpaceID: display.spaces.last!.id)
        }, windows: [])
        XCTAssertTrue(before.hasSameDisplayStructure(as: switched))
        XCTAssertFalse(before.hasSameDisplayStructure(as: snapshot([space(11,b),space(10,a)], [space(1)])))
        XCTAssertFalse(before.hasSameDisplayStructure(as: snapshot([space(10,c),space(11,b)], [space(1)])))
    }
    func testZeroUUIDIsNotStableIdentityAndOriginalWinsAfterFallbackCreation() throws {
        XCTAssertNil(space(10,UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).stableUUID)
        let profile = try LayoutProfile.capture(snapshot: snapshot([space(10,a),space(11,b)], [space(1)]))
        var registry = try ExternalDesktopRegistry(profile: profile)
        let before = snapshot([space(100)], [space(1)])
        let created = snapshot([space(100),space(200,c)], [space(1)])
        try registry.recordCreated(before: before, after: created, slot: 1, sessionID: session)
        XCTAssertEqual(registry.slots[1].stableUUID, b)
        let reappeared = snapshot([space(100),space(200,c)], [space(1),space(11,b)])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: reappeared, registry: registry, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(step.spaceID, 11)
        XCTAssertEqual(step.targetIndex, 1)
    }

}
