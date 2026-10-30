import Foundation
import Testing
@testable import EpocharyKit

struct PassphraseTests {
    @Test func generatedPassphrasesAreTenWordsFromTheList() {
        #expect(Passphrase.words.count == 2048)
        #expect(Set(Passphrase.words).count == 2048)
        let words = Passphrase.generate().split(separator: "-").map(String.init)
        #expect(words.count == 10)
        #expect(words.allSatisfy(Passphrase.words.contains))
        #expect(Passphrase.generate() != Passphrase.generate())
        #expect(Passphrase.warnings(for: Passphrase.generate()).isEmpty)
    }

    @Test func passphrasesMustBeTypeableOnOneLine() throws {
        #expect(throws: EpocharyError.self) { try Passphrase.validate("") }
        #expect(throws: EpocharyError.self) { try Passphrase.validate("two\nlines") }
        #expect(throws: EpocharyError.self) { try Passphrase.validate("tab\there") }
        #expect(throws: EpocharyError.self) { try Passphrase.validate(" leading space") }
        #expect(throws: EpocharyError.self) { try Passphrase.validate("trailing space ") }
        try Passphrase.validate("inner spaces are fine")
    }

    @Test func warnsAboutShortOrHardToTypePassphrases() {
        #expect(Passphrase.warnings(for: "hunter2").count == 1)
        #expect(Passphrase.warnings(for: "orbit lamp chisel meadow quartz").isEmpty)
        #expect(Passphrase.warnings(for: "orbit lamp chisel meadow quartz ünïcødé").count == 1)
    }

    @Test func ageGetsThePassphraseThroughThePlugin() {
        var request = ArchiveRequest(sources: [], destinationDirectory: URL(fileURLWithPath: "/tmp"), name: "a",
                                     recipients: [Recipient(label: "", publicKey: "age1ignored")])
        let plugin = URL(fileURLWithPath: "/Apps/Epochary.app/Contents/Helpers/age-plugin-batchpass")
        #expect(CommandLines.age(request, passphrasePlugin: plugin).arguments == ["-r", "age1ignored"])

        request.passphrase = "cafe\u{301} au lait"  // "é" typed as e + combining accent
        let age = CommandLines.age(request, passphrasePlugin: plugin)
        #expect(age.arguments == ["-e", "-j", "batchpass"])
        #expect(age.environment["AGE_PASSPHRASE"] == "caf\u{e9} au lait")
        #expect(age.environment["PATH"]?.hasPrefix("/Apps/Epochary.app/Contents/Helpers:") == true)
    }
}

/// Encrypts with a passphrase, then restores by typing it into age's own prompt, exactly
/// as the README says. Skipped when the tools or `expect` aren't available.
@Suite(.enabled(if: Tool.allCases.allSatisfy { ToolLocator().locate($0) != nil }
                && FileManager.default.isExecutableFile(atPath: "/usr/bin/expect"),
                "gtar, zstd, age, age-plugin-batchpass, par2 and expect must be installed"))
struct PassphraseIntegrationTests {
    let tools = ToolLocator()
    let passphrase = "orbit lamp chisel meadow quartz"

    @Test func restoresByTypingThePassphrase() async throws {
        let root = try TemporaryDirectory()
        let source = try makeSource(in: root)
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "secret",
                                     recipients: [], compressionLevel: 3, parityPercent: 5, passphrase: passphrase)
        let result = try await ArchivePipeline(tools: tools, appVersion: "test").run(request)
        let folder = result.layout.folder

        // A standard age passphrase file, with nothing that needs the plugin to open it.
        let header = try String(decoding: Data(contentsOf: result.layout.encryptedArchive).prefix(100), as: UTF8.self)
        #expect(header.hasPrefix("age-encryption.org/v1\n-> scrypt "))

        let readme = try String(contentsOf: result.layout.readme, encoding: .utf8)
        #expect(readme.contains("ENCRYPTED WITH A PASSPHRASE"))
        #expect(!readme.contains("key.txt"))
        let command = try #require(readme.split(separator: "\n").first { $0.contains("| tar -xf - -C restored") })
            .trimmingCharacters(in: .whitespaces)
        #expect(command == "age -d secret.tar.zst.age | zstd -d --long=31 | tar -xf - -C restored")

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("restored"), withIntermediateDirectories: false)
        try typingPassphrases(into: command, in: folder)
        try shell("diff -r \(source.path.quoted) restored/data", in: folder)

        #expect(throws: ShellError.self) {
            try shell("AGE_PASSPHRASE='wrong guess' age -d -j batchpass secret.tar.zst.age > /dev/null", in: folder)
        }
    }

    @Test func streamsSegmentsFromMediaWhileAskingForThePassphrase() async throws {
        let root = try TemporaryDirectory()
        let source = try makeSource(in: root)
        let staging = root.url.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let request = ArchiveRequest(sources: [source], destinationDirectory: staging, name: "tapes",
                                     recipients: [], compressionLevel: 3,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: false),
                                     passphrase: passphrase)
        let result = try await ArchivePipeline(tools: tools, appVersion: "test").run(request)
        #expect(result.segments.count >= 3)

        // The README's media-swap loop, answering its "press Return" prompts and age's
        // passphrase prompt, which share the terminal.
        let readme = try String(contentsOf: result.layout.readme, encoding: .utf8)
        let start = try #require(readme.range(of: "MEDIUM=/Volumes/MEDIUM"))
        let end = try #require(readme.range(of: "tar -xf - -C restored", range: start.upperBound..<readme.endIndex))
        let script = String(readme[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: "MEDIUM=/Volumes/MEDIUM", with: "MEDIUM=\(result.layout.folder.path.quoted)")
        #expect(script.contains("done | age -d | zstd"))
        let work = root.url.appendingPathComponent("streamed")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try typingPassphrases(into: script, in: work)
        try shell("diff -r \(source.path.quoted) restored/data", in: work)
    }

    @Test func changeListIsEncryptedWithThePassphrase() async throws {
        let root = try TemporaryDirectory()
        let source = try makeSource(in: root)
        let changes = [SourceChange(path: "data/a.bin", kind: .changed)]
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "x",
                                     recipients: [], passphrase: passphrase)
        let executables = ArchivePipeline.Executables(tar: try tools.require(.tar), zstd: try tools.require(.zstd),
                                                      age: try tools.require(.age),
                                                      agePassphrasePlugin: try tools.require(.agePassphrasePlugin),
                                                      par2: nil)
        let layout = ArchiveLayout(name: "x", destinationDirectory: root.url)
        let data = try await ArchivePipeline.encryptedChangeList(changes, layout: layout, request: request,
                                                                 executables: executables)
        let file = root.url.appendingPathComponent("x.changes.txt.age")
        try data.write(to: file)
        let list = try shell("AGE_PASSPHRASE=\(passphrase.quoted) age -d -j batchpass x.changes.txt.age", in: root.url)
        #expect(list.hasSuffix("changed\tdata/a.bin"))
    }

    @Test func refusesAnInvalidPassphraseBeforeWritingAnything() async throws {
        let root = try TemporaryDirectory()
        let source = try makeSource(in: root)
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "bad",
                                     recipients: [], passphrase: "two\nlines")
        await #expect(throws: EpocharyError.self) { try await ArchivePipeline(tools: tools).run(request) }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("bad").path))
    }

    private func makeSource(in root: TemporaryDirectory) throws -> URL {
        let source = root.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data((0..<1_800_000).map { _ in UInt8.random(in: 0...255) }).write(to: source.appendingPathComponent("a.bin"))
        try Data((0..<1_700_000).map { _ in UInt8.random(in: 0...255) }).write(to: source.appendingPathComponent("sub/b.bin"))
        return source
    }

    /// Runs `script` in a terminal, pressing Return at each "Insert the medium" prompt and
    /// typing the passphrase when age asks for it.
    private func typingPassphrases(into script: String, in directory: URL) throws {
        let scriptFile = directory.appendingPathComponent("restore.sh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let expectFile = directory.appendingPathComponent("restore.exp")
        try """
        set timeout 120
        spawn /bin/bash \(scriptFile.path)
        expect {
            "press Return" { send "\\r"; exp_continue }
            "passphrase:" { send "\(passphrase)\\r"; exp_continue }
            eof
        }
        catch wait result
        exit [lindex $result 3]
        """.write(to: expectFile, atomically: true, encoding: .utf8)
        try shell("/usr/bin/expect \(expectFile.path.quoted)", in: directory)
    }
}
