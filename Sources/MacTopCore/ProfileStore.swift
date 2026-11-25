import CryptoKit
import Foundation

public struct ProfileStore: Sendable {
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("MacTop", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = ProfileStore.defaultDirectory) {
        self.directory = directory
    }

    public func load(_ topology: ProfileTopology) throws -> LayoutProfile? {
        if let profile = try loadProfile(at: fileURL(for: topology), expected: topology) { return profile }
        guard case .external = topology,
              let legacy = try read(LayoutProfile.self, at: legacyProfileURL),
              legacy.topology == topology else { return nil }
        try legacy.validate()
        return legacy
    }

    private func loadProfile(at url: URL, expected topology: ProfileTopology) throws -> LayoutProfile? {
        guard let profile = try read(LayoutProfile.self, at: url) else { return nil }
        try profile.validate()
        guard profile.topology == topology else {
            if case let .external(id) = profile.topology { throw MacTopCoreError.externalMonitorConflict(id) }
            throw MacTopCoreError.invalidProfile("The file does not belong to the requested profile.")
        }
        return profile
    }

    public func save(_ profile: LayoutProfile) throws {
        try profile.validate()
        // Reading before replacing also preserves a corrupt file for diagnosis instead of silently overwriting it.
        let url = fileURL(for: profile.topology)
        _ = try loadProfile(at: url, expected: profile.topology)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func loadExternalDesktopRegistry(profile: LayoutProfile) throws -> ExternalDesktopRegistry? {
        guard case let .external(displayID) = profile.topology else { return nil }
        let registry: ExternalDesktopRegistry
        if let scoped = try read(ExternalDesktopRegistry.self, at: registryURL(for: displayID)) {
            registry = scoped
        } else {
            // The old registry belongs only to the legacy capture. Leave both original files in place.
            guard !FileManager.default.fileExists(atPath: fileURL(for: profile.topology).path),
                  try read(LayoutProfile.self, at: legacyProfileURL) == profile,
                  let legacy = try read(ExternalDesktopRegistry.self, at: directory.appendingPathComponent("external-desktop-identities.json"))
            else { return nil }
            registry = legacy
        }
        guard registry.matches(profile: profile) else { return nil }
        try registry.validate(profile: profile)
        return registry
    }

    public func saveExternalDesktopRegistry(_ registry: ExternalDesktopRegistry, profile: LayoutProfile) throws {
        try registry.validate(profile: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: registryURL(for: registry.displayID), options: .atomic)
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private var legacyProfileURL: URL { directory.appendingPathComponent("macbook-external.json") }

    private func fileURL(for topology: ProfileTopology) -> URL {
        let name: String
        switch topology {
        case .portable: name = "macbook.json"
        case let .external(displayID): name = "macbook-external-\(monitorFileKey(displayID)).json"
        }
        return directory.appendingPathComponent(name)
    }

    private func registryURL(for displayID: String) -> URL {
        directory.appendingPathComponent("external-desktop-identities-\(monitorFileKey(displayID)).json")
    }

    private func monitorFileKey(_ displayID: String) -> String {
        SHA256.hash(data: Data(displayID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
