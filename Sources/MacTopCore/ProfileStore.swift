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
        let url = fileURL(for: topology)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let profile = try JSONDecoder().decode(LayoutProfile.self, from: Data(contentsOf: url))
        try profile.validate()
        guard profile.topology == topology else {
            if case let .external(id) = profile.topology { throw MacTopCoreError.externalMonitorConflict(id) }
            throw MacTopCoreError.invalidProfile("El archivo no pertenece al perfil solicitado.")
        }
        return profile
    }

    public func save(_ profile: LayoutProfile) throws {
        try profile.validate()
        // Reading before replacing also preserves a corrupt file for diagnosis instead of silently overwriting it.
        _ = try load(profile.topology)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: profile.topology), options: .atomic)
    }

    public func loadExternalDesktopRegistry(profile: LayoutProfile) throws -> ExternalDesktopRegistry? {
        let url = directory.appendingPathComponent("external-desktop-identities.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let registry = try JSONDecoder().decode(ExternalDesktopRegistry.self, from: Data(contentsOf: url))
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
        try data.write(to: directory.appendingPathComponent("external-desktop-identities.json"), options: .atomic)
    }

    private func fileURL(for topology: ProfileTopology) -> URL {
        let name: String
        switch topology {
        case .portable: name = "macbook.json"
        case .external: name = "macbook-external.json"
        }
        return directory.appendingPathComponent(name)
    }
}
