import Foundation

/// Everything needed to produce one archive.
public struct ArchiveRequest: Sendable {
    public var sources: [URL]
    /// The archive set is written to a new folder named `name` inside this directory.
    public var destinationDirectory: URL
    public var name: String
    public var recipients: [Recipient]
    /// zstd level; 20–22 enable `--ultra`.
    public var compressionLevel: Int
    /// Use a 2 GiB long-distance matching window (`--long=31`).
    public var longWindow: Bool
    /// PAR2 redundancy in percent, or nil for none.
    public var parityPercent: Int?
    public var excludeFinderMetadata: Bool
    /// Decompress and list the stream while it's written, before anything is kept.
    public var verify: Bool
    /// Split the encrypted archive into segments, or nil for a single file.
    public var segmentation: SegmentOptions?
    /// Stop as soon as tar reports a file changing or disappearing, instead of
    /// finishing an archive that isn't a consistent copy.
    public var stopOnSourceChange: Bool

    public init(sources: [URL], destinationDirectory: URL, name: String, recipients: [Recipient],
                compressionLevel: Int = 19, longWindow: Bool = true, parityPercent: Int? = nil,
                excludeFinderMetadata: Bool = true, verify: Bool = true,
                segmentation: SegmentOptions? = nil, stopOnSourceChange: Bool = false) {
        self.sources = sources
        self.destinationDirectory = destinationDirectory
        self.name = name
        self.recipients = recipients
        self.compressionLevel = compressionLevel
        self.longWindow = longWindow
        self.parityPercent = parityPercent
        self.excludeFinderMetadata = excludeFinderMetadata
        self.verify = verify
        self.segmentation = segmentation
        self.stopOnSourceChange = stopOnSourceChange
    }

    public static let parityOptions = [3, 5, 10]
}

/// File names of an archive set.
public struct ArchiveLayout: Sendable, Equatable {
    public let name: String
    public let folder: URL

    public init(name: String, destinationDirectory: URL) {
        self.name = name
        self.folder = destinationDirectory.appendingPathComponent(name, isDirectory: true)
    }

    public var compressedFileName: String { "\(name).tar.zst" }
    public var encryptedFileName: String { "\(name).tar.zst.age" }
    public var parityFileName: String { "\(encryptedFileName).par2" }

    public var encryptedArchive: URL { folder.appendingPathComponent(encryptedFileName) }
    public var compressedChecksum: URL { folder.appendingPathComponent("\(compressedFileName).sha256") }
    public var encryptedChecksum: URL { folder.appendingPathComponent("\(encryptedFileName).sha256") }
    public var parityIndex: URL { folder.appendingPathComponent(parityFileName) }
    public var readme: URL { folder.appendingPathComponent("\(name).README.txt") }
    /// The encrypted list of files that changed while archiving, when there were any.
    public var changesFileName: String { "\(name).changes.txt.age" }
    public var changesFile: URL { folder.appendingPathComponent(changesFileName) }

    /// A line in GNU coreutils format, verifiable with `sha256sum -c` or `shasum -a 256 -c`.
    public static func checksumLine(hexDigest: String, fileName: String) -> String {
        "\(hexDigest)  \(fileName)\n"
    }

    public static func validateName(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw EpocharyError.invalidArchiveName("it can't be empty.")
        }
        if name != name.trimmingCharacters(in: .whitespaces) {
            throw EpocharyError.invalidArchiveName("it can't start or end with a space.")
        }
        if name.hasPrefix(".") || name.hasPrefix("-") {
            throw EpocharyError.invalidArchiveName("it can't start with “.” or “-”.")
        }
        if name.contains(where: { "/:\\".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) {
            throw EpocharyError.invalidArchiveName("it can't contain / : \\ or control characters.")
        }
        if name.utf8.count > 200 {
            throw EpocharyError.invalidArchiveName("it's too long.")
        }
    }

    public static func defaultName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "archive-\(formatter.string(from: date))"
    }
}

/// One top-level entry in the tar: stored as `name`, read from inside `parent`.
struct TarMember: Equatable {
    let parent: URL
    let name: String

    /// Each dropped item is stored under its own name at the root of the archive.
    static func plan(for sources: [URL]) throws -> [TarMember] {
        guard !sources.isEmpty else { throw EpocharyError.noSources }
        var seen = Set<String>()
        return try sources.map { source in
            let url = source.standardizedFileURL
            // lstat, so a dropped symlink is archived as a link even if its target is gone.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
                throw EpocharyError.sourceMissing(url)
            }
            let name = url.lastPathComponent
            guard url.path != "/" else { throw EpocharyError.invalidArchiveName("the root folder can't be archived.") }
            guard seen.insert(name).inserted else { throw EpocharyError.duplicateItemName(name) }
            return TarMember(parent: url.deletingLastPathComponent(), name: name)
        }
    }
}

enum CommandLines {
    static func tar(members: [TarMember], excludeFinderMetadata: Bool) -> [String] {
        var arguments = ["--create", "--file=-", "--format=pax", "--sort=name", "--numeric-owner"]
        if excludeFinderMetadata { arguments.append("--exclude=.DS_Store") }
        for member in members {
            arguments.append("--directory=\(member.parent.path)")
            // A leading "-" would be read as an option.
            arguments.append(member.name.hasPrefix("-") ? "./\(member.name)" : member.name)
        }
        return arguments
    }

    static func zstdCompress(level: Int, longWindow: Bool) -> [String] {
        var arguments: [String] = []
        if level > 19 { arguments.append("--ultra") }
        arguments.append("-\(level)")
        if longWindow { arguments.append("--long=31") }
        arguments += ["-T0", "--no-progress", "-c", "-"]
        return arguments
    }

    static func zstdTest(longWindow: Bool) -> [String] {
        (longWindow ? ["--long=31"] : []) + ["-d", "--no-progress", "-c", "-"]
    }

    static let tarList = ["--list", "--file=-"]

    static func age(recipients: [Recipient]) -> [String] {
        recipients.flatMap { ["-r", $0.publicKey] }
    }

    static func par2(percent: Int, fileName: String) -> [String] {
        ["create", "-r\(percent)", "--", "\(fileName).par2", fileName]
    }
}
