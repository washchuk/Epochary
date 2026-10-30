import EpocharyKit
import Foundation
import Observation

/// Saved age public keys. Private keys are never stored by Epochary.
@MainActor @Observable
final class KeyStore {
    private static let defaultsKey = "recipients"

    var recipients: [Recipient] {
        didSet { save() }
    }

    init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
        recipients = data.flatMap { try? JSONDecoder().decode([Recipient].self, from: $0) } ?? []
    }

    func add(_ recipient: Recipient) {
        recipients.append(recipient)
    }

    func remove(_ id: Recipient.ID) {
        recipients.removeAll { $0.id == id }
    }

    func contains(publicKey: String) -> Bool {
        recipients.contains { $0.publicKey == publicKey }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recipients), forKey: Self.defaultsKey)
    }
}

/// Tool locations and archive defaults from the Settings window.
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var toolOverrides: [Tool: String] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: toolOverrides.map { ($0.key.rawValue, $0.value) }),
                         forKey: "toolOverrides")
        }
    }

    var compressionLevel: Int {
        didSet { defaults.set(compressionLevel, forKey: "compressionLevel") }
    }

    var longWindow: Bool {
        didSet { defaults.set(longWindow, forKey: "longWindow") }
    }

    var verify: Bool {
        didSet { defaults.set(verify, forKey: "verify") }
    }

    var excludeFinderMetadata: Bool {
        didSet { defaults.set(excludeFinderMetadata, forKey: "excludeFinderMetadata") }
    }

    init() {
        defaults.register(defaults: ["compressionLevel": 19, "longWindow": true, "verify": true,
                                     "excludeFinderMetadata": true])
        let stored = defaults.dictionary(forKey: "toolOverrides") as? [String: String] ?? [:]
        toolOverrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Tool(rawValue: key).map { ($0, value) }
        })
        compressionLevel = defaults.integer(forKey: "compressionLevel")
        longWindow = defaults.bool(forKey: "longWindow")
        verify = defaults.bool(forKey: "verify")
        excludeFinderMetadata = defaults.bool(forKey: "excludeFinderMetadata")
    }

    var toolLocator: ToolLocator {
        ToolLocator(overrides: toolOverrides.mapValues { URL(fileURLWithPath: $0) })
    }
}
