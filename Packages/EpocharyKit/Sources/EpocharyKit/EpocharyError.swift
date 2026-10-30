import Foundation

public enum EpocharyError: LocalizedError, Equatable {
    case toolMissing(Tool)
    case noSources
    case noRecipients
    case invalidPassphrase(String)
    case invalidArchiveName(String)
    case sourceMissing(URL)
    case duplicateItemName(String)
    case destinationMissing(URL)
    case destinationExists(URL)
    case destinationInsideSource(source: URL)
    case destinationIsTape(URL)
    case notEnoughSpace(needed: Int64, available: Int64)
    case sourceChanged(SourceChange)
    case invalidRecipient(String, reason: String)
    case processFailed(Tool, status: Int32, message: String)
    case verificationFailed(String)
    case keyFileExists(URL)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            "\(tool.displayName) (\(tool.executableName)) wasn't found. Install it with “brew install \(tool.homebrewFormula)” or set its path in Settings."
        case .noSources:
            "Add at least one file or folder to archive."
        case .noRecipients:
            "Choose at least one age key to encrypt to."
        case .invalidPassphrase(let reason):
            "Invalid passphrase: \(reason)"
        case .invalidArchiveName(let reason):
            "Invalid archive name: \(reason)"
        case .sourceMissing(let url):
            "“\(url.path)” no longer exists."
        case .duplicateItemName(let name):
            "Two items are named “\(name)”. Items from different folders must have different names, or one would overwrite the other when restored."
        case .destinationMissing(let url):
            "The destination folder “\(url.path)” doesn't exist."
        case .destinationExists(let url):
            "“\(url.lastPathComponent)” already exists in the destination folder. Choose a different archive name."
        case .destinationInsideSource(let source):
            "The destination is inside “\(source.lastPathComponent)”, which is being archived. Choose a destination outside the items being archived."
        case .destinationIsTape(let url):
            "“\(url.lastPathComponent)” is an LTFS tape. Segments are staged on a disk, external drive or network share first, then copied to tape."
        case .notEnoughSpace(let needed, let available):
            "The destination has \(available.formatted(.byteCount(style: .file))) free, but needs \(needed.formatted(.byteCount(style: .file)))."
        case .sourceChanged(let change):
            "“\(change.path)” \(change.summary), so Epochary stopped and kept nothing. Archive it again once the files "
                + "have stopped changing, or turn off “Stop if files change”."
        case .invalidRecipient(let key, let reason):
            "“\(key.prefix(24))…” isn't a usable age recipient: \(reason)"
        case .processFailed(let tool, let status, let message):
            "\(tool.displayName) failed (exit status \(status)).\n\(message)"
        case .verificationFailed(let message):
            "The compressed stream failed verification, so nothing was kept.\n\(message)"
        case .keyFileExists(let url):
            "“\(url.lastPathComponent)” already exists. age-keygen never overwrites a key file."
        }
    }
}
