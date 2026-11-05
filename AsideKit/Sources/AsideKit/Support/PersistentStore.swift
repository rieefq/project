import Foundation

/// Durable key–value storage for Aside's own data (memory, journal, preferences).
///
/// The apps back this with encrypted files whose key lives in the Keychain; tests use
/// the in-memory store. Keys are short, fixed names — never user content.
public protocol PersistentStore: Sendable {
    func load(_ key: String) async throws -> Data?
    func save(_ data: Data, for key: String) async throws
    func remove(_ key: String) async throws
}

public actor InMemoryStore: PersistentStore {
    private var values: [String: Data] = [:]

    public init() {}

    public func load(_ key: String) async throws -> Data? { values[key] }
    public func save(_ data: Data, for key: String) async throws { values[key] = data }
    public func remove(_ key: String) async throws { values[key] = nil }
    public func keys() -> [String] { values.keys.sorted() }
}

/// Codable persistence helpers with consistent date handling.
public enum StoreCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Preferences {
    /// Decodes stored preferences over the current defaults, so settings saved by an
    /// older version (missing newer keys) still load instead of resetting.
    public static func decodeLenient(_ data: Data) -> Preferences {
        guard let stored = try? JSONValue.parse(data),
              let defaultsData = try? StoreCoding.encoder().encode(Preferences()),
              let defaults = try? JSONValue.parse(defaultsData) else { return Preferences() }
        let merged = deepMerge(defaults, stored)
        return (try? StoreCoding.decoder().decode(Preferences.self, from: merged.serialized())) ?? Preferences()
    }

    static func deepMerge(_ base: JSONValue, _ overlay: JSONValue) -> JSONValue {
        guard case .object(var result) = base, case .object(let top) = overlay else { return overlay }
        for (key, value) in top {
            if let existing = result[key], case .object = existing, case .object = value {
                result[key] = deepMerge(existing, value)
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
}
