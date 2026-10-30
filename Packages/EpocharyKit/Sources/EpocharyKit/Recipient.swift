import Foundation

/// An age public key that archives can be encrypted to. Only public keys are ever
/// stored by Epochary; private keys stay wherever the user keeps them.
public struct Recipient: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var publicKey: String

    public init(id: UUID = UUID(), label: String, publicKey: String) {
        self.id = id
        self.label = label
        self.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap syntactic check for UI feedback. `RecipientValidator` asks age itself.
    public static func looksLikePublicKey(_ text: String) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("ssh-ed25519 ") || key.hasPrefix("ssh-rsa ") { return true }
        // Native, post-quantum and plugin recipients are all Bech32 strings starting "age1".
        let bech32 = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l1")
        return key.hasPrefix("age1") && key.count >= 62 && key.allSatisfy { bech32.contains($0) }
    }
}

public enum RecipientValidator {
    /// Asks age to encrypt an empty message to the key, which is the authoritative check.
    public static func validate(_ publicKey: String, tools: ToolLocator) async throws {
        let age = try tools.require(.age)
        let result = try await ProcessRunner.capture(age, arguments: ["-r", publicKey])
        guard result.status == 0 else {
            let reason = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "rejected by age"
            throw EpocharyError.invalidRecipient(publicKey, reason: reason)
        }
    }
}

public enum KeyGenerator {
    /// Creates a new identity file with age-keygen and returns its public key.
    /// - Parameter postQuantum: hybrid ML-KEM-768 + X25519 keys; decrypting needs age 1.3 or newer.
    public static func generateIdentity(at url: URL, postQuantum: Bool, tools: ToolLocator) async throws -> String {
        let keygen = try tools.require(.ageKeygen)
        if FileManager.default.fileExists(atPath: url.path) { throw EpocharyError.keyFileExists(url) }
        var arguments = ["-o", url.path]
        if postQuantum { arguments.insert("-pq", at: 0) }
        let result = try await ProcessRunner.capture(keygen, arguments: arguments)
        guard result.status == 0 else {
            throw EpocharyError.processFailed(.ageKeygen, status: result.status, message: result.stderr)
        }
        // age-keygen restricts the file to the owner already; make sure regardless.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try await publicKey(forIdentityAt: url, tools: tools)
    }

    /// Derives the public key from an existing identity file (`age-keygen -y`).
    public static func publicKey(forIdentityAt url: URL, tools: ToolLocator) async throws -> String {
        let keygen = try tools.require(.ageKeygen)
        let result = try await ProcessRunner.capture(keygen, arguments: ["-y", url.path])
        guard result.status == 0,
              let key = result.stdout.split(whereSeparator: \.isNewline).first.map(String.init) else {
            throw EpocharyError.processFailed(.ageKeygen, status: result.status, message: result.stderr)
        }
        return key
    }
}
