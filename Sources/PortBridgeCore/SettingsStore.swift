import Foundation

public final class SettingsStore: Sendable {
    public let configurationURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configurationURL: URL? = nil) {
        if let configurationURL {
            self.configurationURL = configurationURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.configurationURL = base
                .appendingPathComponent("PortBridge", isDirectory: true)
                .appendingPathComponent("config.json")
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return AppConfiguration()
        }
        let data = try Data(contentsOf: configurationURL)
        return try decoder.decode(AppConfiguration.self, from: data)
    }

    public func save(_ configuration: AppConfiguration) throws {
        let dir = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL, options: [.atomic])
    }
}
