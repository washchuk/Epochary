import Foundation

/// The external command-line tools Epochary drives.
public enum Tool: String, CaseIterable, Sendable, Codable {
    case tar = "gtar"
    case zstd
    case age
    case ageKeygen = "age-keygen"
    /// age's plugin for passphrases supplied by a program rather than typed at a terminal.
    case agePassphrasePlugin = "age-plugin-batchpass"
    case par2

    /// The executable name to look for on disk.
    public var executableName: String { rawValue }

    public var displayName: String {
        switch self {
        case .tar: "GNU tar"
        case .zstd: "Zstandard"
        case .age: "age"
        case .ageKeygen: "age-keygen"
        case .agePassphrasePlugin: "age passphrase plugin"
        case .par2: "par2"
        }
    }

    /// Homebrew formula that provides the tool.
    public var homebrewFormula: String {
        switch self {
        case .tar: "gnu-tar"
        case .zstd: "zstd"
        case .age, .ageKeygen, .agePassphrasePlugin: "age"
        case .par2: "par2"
        }
    }

    public var homepage: String {
        switch self {
        case .tar: "https://www.gnu.org/software/tar/"
        case .zstd: "https://facebook.github.io/zstd/"
        case .age, .ageKeygen, .agePassphrasePlugin: "https://age-encryption.org"
        case .par2: "https://github.com/Parchive/par2cmdline"
        }
    }

    /// The homepage of the implementation that printed `versionLine`; Epochary bundles
    /// par2cmdline-turbo, but a user may point it at the original par2cmdline.
    public func homepage(forVersion versionLine: String?) -> String {
        if self == .par2, versionLine?.localizedCaseInsensitiveContains("turbo") == true {
            return "https://github.com/animetosho/par2cmdline-turbo"
        }
        return homepage
    }

    /// par2 is only needed when recovery data is requested, age-keygen only for generating
    /// keys, and the passphrase plugin only for passphrase encryption.
    public var isRequiredForArchiving: Bool {
        switch self {
        case .tar, .zstd, .age: true
        case .ageKeygen, .agePassphrasePlugin, .par2: false
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

    /// Where the app bundles its own builds of the tools (Vendor/build-tools.sh).
    public static var bundledDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    /// Explicit per-tool paths chosen by the user; these win over everything else.
    public var overrides: [Tool: URL]
    /// Directories searched in order: the app's bundled tools, then package managers.
    public var searchDirectories: [URL]

    /// `EPOCHARY_TOOLS_DIR` restricts the search to one directory, so tests can run
    /// against a particular set of builds.
    public init(overrides: [Tool: URL] = [:], searchDirectories: [URL]? = nil) {
        self.overrides = overrides
        if let searchDirectories {
            self.searchDirectories = searchDirectories
        } else if let only = ProcessInfo.processInfo.environment["EPOCHARY_TOOLS_DIR"] {
            self.searchDirectories = [URL(fileURLWithPath: only, isDirectory: true)]
        } else {
            self.searchDirectories = [Self.bundledDirectory] + Self.defaultSearchDirectories
        }
    }

    public func locate(_ tool: Tool) -> URL? {
        if let override = overrides[tool] {
            return Self.isExecutable(override) ? override : nil
        }
        return searchDirectories.map { $0.appendingPathComponent(tool.executableName) }
            .first(where: Self.isExecutable)
    }

    /// True when `url` is one of the copies shipped inside the app.
    public static func isBundled(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == bundledDirectory.standardizedFileURL.path
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
