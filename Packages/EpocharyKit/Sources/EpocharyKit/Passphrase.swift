import Foundation

/// Passphrases for age's scrypt mode. They're never stored: they go to age through
/// its batchpass plugin and are typed again at `age -d` when restoring.
public enum Passphrase {
    /// Ten random words, the same shape as the passphrases `age -p` suggests: about 110 bits.
    public static func generate(wordCount: Int = 10) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<wordCount).map { _ in words.randomElement(using: &generator)! }.joined(separator: "-")
    }

    /// Accented letters can be typed as one character or as a letter plus an accent; both
    /// become the single-character form, which is what keyboards usually produce.
    static func normalized(_ passphrase: String) -> String {
        passphrase.precomposedStringWithCanonicalMapping
    }

    /// age reads a passphrase as one line typed at a terminal, so it has to be typeable there.
    public static func validate(_ passphrase: String) throws {
        if passphrase.isEmpty {
            throw EpocharyError.invalidPassphrase("it can't be empty.")
        }
        if passphrase.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw EpocharyError.invalidPassphrase("it can't contain line breaks, tabs or other control characters.")
        }
        if passphrase != passphrase.trimmingCharacters(in: .whitespaces) {
            throw EpocharyError.invalidPassphrase("it can't start or end with a space, which is too easy to miss when typing it again.")
        }
    }

    /// Reasons a valid passphrase may still be a poor choice for an archive meant to last decades.
    public static func warnings(for passphrase: String) -> [String] {
        var warnings: [String] = []
        let words = passphrase.split { !$0.isLetter && !$0.isNumber }.count
        if passphrase.count < 20 && words < 5 {
            warnings.append("Anyone with a copy of the archive can keep guessing for years. Use at least five "
                            + "random words, or generate a passphrase.")
        }
        if !passphrase.allSatisfy(\.isASCII) {
            warnings.append("Characters outside plain English letters, digits and punctuation may be hard to type "
                            + "on another computer years from now.")
        }
        return warnings
    }
}
