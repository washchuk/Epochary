import Foundation
import Testing
@testable import EpocharyKit

/// Runs the real tools end to end, then restores with plain shell commands, exactly
/// as the README tells someone to. Skipped when the tools aren't installed.
@Suite(.enabled(if: Tool.allCases.allSatisfy { ToolLocator().locate($0) != nil }, "gtar, zstd, age and par2 must be installed"))
struct PipelineIntegrationTests {
    let tools = ToolLocator()

    @Test func archiveThenRestoreRoundTrips() async throws {
        let root = try TemporaryDirectory()
        let sources = try makeSampleSources(in: root.url.appendingPathComponent("sources"))
        let output = root.url.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        #expect(publicKey.hasPrefix("age1"))

        let stages = StageLog()
        let request = ArchiveRequest(sources: sources, destinationDirectory: output, name: "archive-test",
                                     recipients: [Recipient(label: "Test key", publicKey: publicKey)],
                                     compressionLevel: 3, parityPercent: 5)
        let result = try await ArchivePipeline(tools: tools, appVersion: "test").run(request) { stages.record($0.stage) }

        #expect(stages.stages == [.preparing, .archiving, .finishing, .creatingParity, .done])
        #expect(result.warnings.isEmpty)
        let names = Set(result.files.map(\.lastPathComponent))
        #expect(names.isSuperset(of: ["archive-test.tar.zst.age", "archive-test.tar.zst.age.sha256",
                                      "archive-test.tar.zst.sha256", "archive-test.tar.zst.age.par2",
                                      "archive-test.README.txt"]))
        #expect(names.contains { $0.hasPrefix("archive-test.tar.zst.age.vol") })
        #expect(!names.contains("archive-test.tar.zst"), "no plaintext may be left behind")

        let folder = result.layout.folder
        // Checksums verify with standard tools.
        try shell("shasum -a 256 -c archive-test.tar.zst.age.sha256", in: folder)
        let decryptedHash = try shell("age -d -i \(keyFile.path.quoted) archive-test.tar.zst.age | shasum -a 256 | cut -d' ' -f1", in: folder)
        let recorded = try String(contentsOf: result.layout.compressedChecksum, encoding: .utf8)
        #expect(recorded == "\(decryptedHash)  archive-test.tar.zst\n")
        #expect(decryptedHash == result.compressedSHA256)

        // Restore with the README's command, using any tar.
        let restored = root.url.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        try shell("age -d -i \(keyFile.path.quoted) archive-test.tar.zst.age | zstd -d --long=31 | tar -xf - -C \(restored.path.quoted)", in: folder)
        for source in sources {
            try shell("diff -r -x .DS_Store \(source.path.quoted) \(restored.appendingPathComponent(source.lastPathComponent).path.quoted)", in: root.url)
        }
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("Folder/Taxes/2024 – Ünïcødé/.DS_Store").path))

        // Damage the archive; par2 detects and repairs it.
        let archive = try FileHandle(forUpdating: result.layout.encryptedArchive)
        try archive.seek(toOffset: 1000)
        try archive.write(contentsOf: Data(repeating: 0xFF, count: 64))
        try archive.close()
        #expect(throws: ShellError.self) { try shell("shasum -a 256 -c archive-test.tar.zst.age.sha256", in: folder) }
        try shell("par2 repair -q archive-test.tar.zst.age.par2", in: folder)
        try shell("shasum -a 256 -c archive-test.tar.zst.age.sha256", in: folder)

        let readme = try String(contentsOf: result.layout.readme, encoding: .utf8)
        #expect(readme.contains(publicKey))
        #expect(readme.contains("zstd -d --long=31"))
        #expect(!readme.contains("Taxes"), "file names must not leak into the plaintext README")
        #expect(readme.contains("GNU tar reported no files changing"))
    }

    @Test func invalidRecipientFailsAndLeavesNothingBehind() async throws {
        let root = try TemporaryDirectory()
        let sources = try makeSampleSources(in: root.url.appendingPathComponent("sources"))
        let bogus = "age1" + String(repeating: "q", count: 58)
        let request = ArchiveRequest(sources: sources, destinationDirectory: root.url, name: "bad",
                                     recipients: [Recipient(label: "", publicKey: bogus)], compressionLevel: 1)
        await #expect {
            try await ArchivePipeline(tools: tools).run(request)
        } throws: { error in
            guard case EpocharyError.processFailed(.age, _, _) = error else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("bad").path))
    }

    @Test func unreadableFileFailsTheArchive() async throws {
        let root = try TemporaryDirectory()
        let sources = try makeSampleSources(in: root.url.appendingPathComponent("sources"))
        let locked = sources[0].appendingPathComponent("locked.txt")
        try "secret".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        let request = ArchiveRequest(sources: sources, destinationDirectory: root.url, name: "partial",
                                     recipients: [Recipient(label: "", publicKey: publicKey)], compressionLevel: 1)
        await #expect {
            try await ArchivePipeline(tools: tools).run(request)
        } throws: { error in
            guard case EpocharyError.processFailed(.tar, _, let message) = error else { return false }
            return message.contains("locked.txt")
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("partial").path))
    }

    @Test func cancellationStopsThePipelineAndCleansUp() async throws {
        let root = try TemporaryDirectory()
        let big = root.url.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try shell("head -c 400000000 /dev/urandom > blob.bin", in: big)
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        let request = ArchiveRequest(sources: [big], destinationDirectory: root.url, name: "cancelled",
                                     recipients: [Recipient(label: "", publicKey: publicKey)])
        let task = Task { try await ArchivePipeline(tools: tools).run(request) }
        try await Task.sleep(for: .seconds(1))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("cancelled").path))
    }

    @Test func publicKeyIsDerivedFromAnIdentityFile() async throws {
        let root = try TemporaryDirectory()
        let keyFile = root.url.appendingPathComponent("key.txt")
        let generated = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        #expect(try await KeyGenerator.publicKey(forIdentityAt: keyFile, tools: tools) == generated)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        await #expect(throws: EpocharyError.keyFileExists(keyFile)) {
            try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        }
        try await RecipientValidator.validate(generated, tools: tools)
    }

    /// Two top-level items: a folder with nested, hidden, Unicode and odd names, and a single file.
    private func makeSampleSources(in directory: URL) throws -> [URL] {
        let folder = directory.appendingPathComponent("Folder")
        let nested = folder.appendingPathComponent("Taxes/2024 – Ünïcødé")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello\n".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "hidden\n".write(to: folder.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
            .write(to: nested.appendingPathComponent("données.bin"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                                   withDestinationPath: "readme.txt")
        let single = directory.appendingPathComponent("-single file.txt")
        try "single\n".write(to: single, atomically: true, encoding: .utf8)
        try "junk".write(to: nested.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        return [folder, single]
    }
}

final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ArchiveProgress.Stage] = []

    func record(_ stage: ArchiveProgress.Stage) {
        lock.withLock { if recorded.last != stage { recorded.append(stage) } }
    }

    var stages: [ArchiveProgress.Stage] { lock.withLock { recorded } }
}

struct ShellError: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let output: String
    var description: String { "`\(command)` exited \(status): \(output)" }
}

@discardableResult
func shell(_ command: String, in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", "set -o pipefail; " + command]
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw ShellError(command: command, status: process.terminationStatus, output: output)
    }
    return output
}

extension String {
    var quoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
