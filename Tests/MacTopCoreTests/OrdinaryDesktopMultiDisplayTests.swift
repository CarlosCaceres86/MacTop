import XCTest
@testable import MacTopCore

final class OrdinaryDesktopMultiDisplayTests: XCTestCase {
    private let session = UUID()
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private func space(_ id: UInt64, _ uuid: UUID? = nil) -> SpaceSnapshot { .init(id: id, kind: .ordinary, stableUUID: uuid) }
    private func snapshot(_ sequences: [[SpaceSnapshot]], builtIn: Bool = true) -> DesktopSnapshot {
        .init(displays: sequences.enumerated().map { index, spaces in
            .init(id: index == 0 && builtIn ? "builtin" : "monitor\(index)", isBuiltIn: index == 0 && builtIn,
                  frame: .init(x: Double(index * 1000), y: 0, width: 1000, height: 800), spaces: spaces)
        }, windows: [])
    }
    private func registries(_ profile: LayoutProfile, snapshot: DesktopSnapshot? = nil) throws -> [ExternalDesktopRegistry] {
        try profile.displays.map { saved in
            if let snapshot { return try .init(profile: profile, role: saved.role, snapshot: snapshot, sessionID: session) }
            return try .init(profile: profile, role: saved.role)
        }
    }
    private func apply(_ step: OrdinaryDesktopReturnStep, to before: DesktopSnapshot) throws -> DesktopSnapshot {
        let moving = try XCTUnwrap(before.displays.first { $0.id == step.sourceDisplayID }?.spaces.first { $0.id == step.spaceID })
        let after = DesktopSnapshot(displays: before.displays.map { display in
            var spaces = display.spaces
            if display.id == step.sourceDisplayID { spaces.removeAll { $0.id == step.spaceID } }
            if display.id == step.targetDisplayID { spaces.insert(moving, at: step.targetIndex) }
            return .init(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame, spaces: spaces)
        }, windows: [])
        XCTAssertTrue(try OrdinaryDesktopReturn.isVerified(before: before, after: after, step: step))
        return after
    }
    private func add(_ id: UInt64, on displayID: String, to before: DesktopSnapshot) throws -> DesktopSnapshot {
        let after = DesktopSnapshot(displays: before.displays.map { display in
            .init(id: display.id, isBuiltIn: display.isBuiltIn, frame: display.frame,
                  spaces: display.spaces + (display.id == displayID ? [space(id, UUID())] : []))
        }, windows: [])
        XCTAssertTrue(try OrdinaryDesktopAddition.isVerified(before: before, after: after, displayID: displayID))
        return after
    }

    func testSoleDesktopSwapCreatesOneRetainedAuxiliaryThenReturnsAllOwners() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a)], [space(2,b)], [space(3,c)]]))
        let registries = try registries(profile)
        var current = snapshot([[space(2,b)], [space(1,a)], [space(3,c)]])
        guard case let .create(displayID, slot, _) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail("swap needs a retained sibling") }
        XCTAssertNil(slot)
        current = try add(100, on: displayID, to: current)
        var moves = 0
        while case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) {
            moves += 1
            XCTAssertLessThanOrEqual(moves, 3)
            if moves > 3 { return }
            current = try apply(step, to: current)
        }
        XCTAssertEqual(moves, 2)
        XCTAssertEqual(current.displays.map { $0.spaces.first?.stableUUID }, [a,b,c])
        XCTAssertEqual(current.displays.flatMap(\.spaces).count, 4)
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session), .ready)
    }

    func testFullTargetWaitsForAnotherExecutableReturnAcrossThreeDisplays() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a)], [space(2,b)], [space(3,c)]]))
        let registries = try registries(profile)
        var current = snapshot([[space(1,a),space(99)], [space(3,c)] + (100...114).map { space(UInt64($0)) }, [space(2,b),space(999)]])
        guard case let .move(first) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(first.spaceID, 3)
        XCTAssertEqual(first.targetDisplayID, "monitor2")
        current = try apply(first, to: current)
        guard case let .move(second) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(second.spaceID, 2)
        current = try apply(second, to: current)
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session), .ready)
    }

    func testCapacityCannotBeSolvedByStealingOrDeletingAnUnknownDesktop() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a)], [space(2,b)], [space(3,c)]]))
        let current = snapshot([[space(1,a)], (100...115).map { space(UInt64($0)) }, [space(3,c),space(2,b)]])
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries(profile), sessionID: session))
    }

    func testMissingSlotDoesNotConsumeAnotherDisplaysOriginalAndCreationGetsRoleIdentity() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a)], [space(2,b)], [space(3,c)]]))
        var registries = try registries(profile)
        let current = snapshot([[space(1,a)], [space(3,c)], [space(100)]])
        guard case let .create(displayID, slot, _) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(displayID, "monitor1")
        XCTAssertEqual(slot, 0)
        let after = try add(200, on: displayID, to: current)
        try registries[1].recordCreated(before: current, after: after, slot: try XCTUnwrap(slot), sessionID: session)
        XCTAssertEqual(registries[1].slots[0].sessionSpaceID, 200)
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: after, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(step.spaceID, 200)
    }

    func testBuiltInRegistryCreationUsesObservedIDAndKeepsLegacyEncoding() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a),space(2,b)], [space(3,c)], [space(4,d)]]))
        var registry = try ExternalDesktopRegistry(profile: profile, role: .builtIn)
        let before = snapshot([[space(100)], [space(3,c)], [space(4,d)]])
        let after = try add(200, on: "builtin", to: before)
        try registry.recordCreated(before: before, after: after, slot: 1, sessionID: session)
        XCTAssertEqual(registry.role, .builtIn)
        XCTAssertEqual(registry.displayID, "")
        XCTAssertEqual(registry.slots[1].sessionSpaceID, 200)
        XCTAssertEqual(try JSONDecoder().decode(ExternalDesktopRegistry.self, from: JSONEncoder().encode(registry)), registry)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["displayID", "capturedAt", "slots"])
    }

    func testFourDisplayReorderingAndClosedLidReturnAreVerified() throws {
        let captured = snapshot([[space(1,a)], [space(2,b)], [space(3,c)], [space(4,d)]], builtIn: false)
        let profile = try LayoutProfile.capture(snapshot: captured)
        let registries = try registries(profile)
        var current = snapshot([[space(4,d),space(100)], [space(1,a),space(101)], [space(2,b),space(102)], [space(3,c),space(103)]], builtIn: false)
        for _ in 0..<8 {
            let step = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session)
            if step == .ready { break }
            guard case let .move(move) = step else { return XCTFail("existing siblings make creation unnecessary") }
            current = try apply(move, to: current)
        }
        XCTAssertEqual(current.displays.map { $0.spaces.first?.stableUUID }, [a,b,c,d])
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session), .ready)
    }

    func testCompleteRegistriesAndExactWholeTopologyAreRequired() throws {
        let captured = snapshot([[space(1,a)], [space(2,b)], [space(3,c)]])
        let profile = try LayoutProfile.capture(snapshot: captured)
        let all = try registries(profile)
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: captured, registries: Array(all.dropLast()), sessionID: session))
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: captured, registries: [all[0],all[1],all[1]], sessionID: session))
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: snapshot([[space(1,a)], [space(2,b)]]), registries: all, sessionID: session))
    }

    func testRecycledSessionNumberIsDiscardedRatherThanAuthorizingAReturn() throws {
        let captured = snapshot([[space(1)], [space(2)], [space(3)]])
        let profile = try LayoutProfile.capture(snapshot: captured)
        let current = snapshot([[space(100)], [space(2),space(1,a)], [space(3)]])
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries(profile, snapshot: captured), sessionID: session), .ready)
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries(profile, snapshot: captured), sessionID: UUID()), .ready)
    }

    func testOriginalUUIDWinsGloballyOverAnotherRolesCreatedIdentity() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a)], [space(2,b)], [space(3,c)]]))
        var registries = try registries(profile)
        let before = snapshot([[space(100)], [space(200)], [space(300)]])
        let created = snapshot([[space(100),space(101,c)], [space(200)], [space(300)]])
        try registries[0].recordCreated(before: before, after: created, slot: 0, sessionID: session)
        var current = snapshot([[space(101,c)], [space(2,b)], [space(1,a),space(300)]])
        guard case let .move(original) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(original.spaceID, 1)
        XCTAssertEqual(original.targetDisplayID, "builtin")
        current = try apply(original, to: current)
        guard case let .move(otherOriginal) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(otherOriginal.spaceID, 101)
        XCTAssertEqual(otherOriginal.targetDisplayID, "monitor2")
        current = try apply(otherOriginal, to: current)
        XCTAssertEqual(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session), .ready)
    }

    func testCompetingCreatedIdentityClaimsAreRejectedAcrossRoles() throws {
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a)], [space(2,b)], [space(3,c)]]))
        let sameCreatedUUID = UUID()
        let registries = try registries(profile).map { registry in
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as? [String: Any])
            var slots = try XCTUnwrap(json["slots"] as? [[String: Any]])
            slots[0]["createdUUID"] = sameCreatedUUID.uuidString
            json["slots"] = slots
            return try JSONDecoder().decode(ExternalDesktopRegistry.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let current = snapshot([[space(100,sameCreatedUUID)], [space(200)], [space(300)]])
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session))
    }

    func testMixedSourceIsNeverDraggedButUnrelatedOrdinaryReturnCanProgress() throws {
        let full = SpaceSnapshot(id: 99, kind: .fullScreen)
        let profile = try LayoutProfile.capture(snapshot: snapshot([[space(1,a),full], [space(2,b)], [space(3,c)], [space(4,d)]]))
        let registries = try registries(profile)
        let current = snapshot([[space(2,b),full], [space(1,a),space(4,d)], [space(3,c)], [space(100)]])
        guard case let .move(step) = try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: current, registries: registries, sessionID: session) else { return XCTFail() }
        XCTAssertEqual(step.spaceID, 4)
        let progressed = try apply(step, to: current)
        XCTAssertThrowsError(try OrdinaryDesktopReturn.nextStep(profile: profile, snapshot: progressed, registries: registries, sessionID: session))
    }

    func testVerifierRejectsUnrelatedThirdDisplayChangesAndPreservesFullscreenSource() throws {
        let before = snapshot([[space(1,a),space(2,b), .init(id: 99, kind: .fullScreen)], [space(100)], [space(3,c)]])
        let move = OrdinaryDesktopReturnStep(spaceID: 2, stableUUID: b, sourceDisplayID: "builtin", targetDisplayID: "monitor1", targetIndex: 0, slot: 0)
        let after = try apply(move, to: before)
        let changed = snapshot([after.displays[0].spaces, after.displays[1].spaces, [space(3,d)]])
        XCTAssertThrowsError(try OrdinaryDesktopReturn.isVerified(before: before, after: changed, step: move))
        XCTAssertThrowsError(try OrdinaryDesktopAddition.isVerified(before: before, after: changed, displayID: "monitor1"))
        let withAuxiliary = try add(200, on: "builtin", to: before)
        XCTAssertEqual(withAuxiliary.displays[0].spaces[2].kind, .fullScreen)
    }
}
