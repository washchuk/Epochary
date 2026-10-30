import Foundation

/// The external command-line tools Epochary drives.
public enum Tool: String, CaseIterable, Sendable, Codable {
    case tar = "gtar"
    case zstd
    case age
    case ageKeygen = "age-keygen"
    case par2

    /// The executable name to look for on disk.
    public var executableName: String { rawValue }

    public var displayName: String {
        switch self {
        case .tar: "GNU tar"
        case .zstd: "Zstandard"
        case .age: "age"
        case .ageKeygen: "age-keygen"
        case .par2: "par2"
        }
    }

    /// Homebrew formula that provides the tool.
    public var homebrewFormula: String {
        switch self {
        case .tar: "gnu-tar"
        case .zstd: "zstd"
        case .age, .ageKeygen: "age"
        case .par2: "par2"
        }
    }

    public var homepage: String {
        switch self {
        case .tar: "https://www.gnu.org/software/tar/"
        case .zstd: "https://facebook.github.io/zstd/"
        case .age, .ageKeygen: "https://age-encryption.org"
        case .par2: "https://github.com/Parchive/par2cmdline"
        }
    }

    /// par2 is only needed when recovery data is requested; age-keygen only for generating keys.
    public var isRequiredForArchiving: Bool {
        switch self {
        case .tar, .zstd, .age: true
        case .ageKeygen, .par2: false
        }
    }
}

/// Finds tool executables. Apps launched from Finder don't inherit the shell's PATH,
/// so the common package-manager locations are searched explicitly.
public struct ToolLocator: Sendable {
    public static let defaultSearchDirectories: [URL] = [
        "/opt/homebrew/bin",   // Homebrew on Apple silicon
        "/usr/local/bin",      // Homebrew on Intel, manual installs
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// Explicit per-tool paths chosen by the user; these win over searching.
    public var overrides: [Tool: URL]
    /// Directories searched in order, after any bundled helpers.
    public var searchDirectories: [URL]

    public init(overrides: [Tool: URL] = [:], searchDirectories: [URL] = ToolLocator.defaultSearchDirectories) {
        self.overrides = overrides
        self.searchDirectories = searchDirectories
    }

    public func locate(_ tool: Tool) -> URL? {
        if let override = overrides[tool] {
            return Self.isExecutable(override) ? override : nil
        }
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: tool.executableName) {
            candidates.append(bundled)
        }
        candidates += searchDirectories.map { $0.appendingPathComponent(tool.executableName) }
        return candidates.first(where: Self.isExecutable)
    }

    public func require(_ tool: Tool) throws -> URL {
        guard let url = locate(tool) else { throw EpocharyError.toolMissing(tool) }
        return url
    }

    /// First line of `<tool> --version`, e.g. "tar (GNU tar) 1.35".
    public func version(of tool: Tool) async -> String? {
        guard let url = locate(tool) else { return nil }
        guard let result = try? await ProcessRunner.capture(url, arguments: ["--version"]) else { return nil }
        let text = result.stdout.isEmpty ? result.stderr : result.stdout
        return text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
