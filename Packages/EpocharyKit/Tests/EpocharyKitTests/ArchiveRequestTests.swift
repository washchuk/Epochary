import Foundation
import Testing
@testable import EpocharyKit

struct ArchiveRequestTests {
    @Test func checksumLineMatchesCoreutilsFormat() {
        #expect(ArchiveLayout.checksumLine(hexDigest: "abc123", fileName: "a b.tar.zst.age") == "abc123  a b.tar.zst.age\n")
    }

    @Test func layoutNamesFollowTheExtensionChain() {
        let layout = ArchiveLayout(name: "archive-2025", destinationDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(layout.folder.path == "/tmp/archive-2025")
        #expect(layout.encryptedArchive.lastPathComponent == "archive-2025.tar.zst.age")
        #expect(layout.encryptedChecksum.lastPathComponent == "archive-2025.tar.zst.age.sha256")
        #expect(layout.compressedChecksum.lastPathComponent == "archive-2025.tar.zst.sha256")
        #expect(layout.parityIndex.lastPathComponent == "archive-2025.tar.zst.age.par2")
    }

    @Test(arguments: ["", " ", " lead", "trail ", ".hidden", "-dash", "a/b", "a:b", "tab\there"])
    func invalidNamesAreRejected(_ name: String) {
        #expect(throws: EpocharyError.self) { try ArchiveLayout.validateName(name) }
    }

    @Test(arguments: ["archive-2025", "Family Photos 1998–2004", "ünïcødé"])
    func validNamesAreAccepted(_ name: String) throws {
        try ArchiveLayout.validateName(name)
    }

    @Test func duplicateTopLevelNamesAreRejected() throws {
        let root = try TemporaryDirectory()
        let a = root.url.appendingPathComponent("a/Photos")
        let b = root.url.appendingPathComponent("b/Photos")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        #expect(throws: EpocharyError.duplicateItemName("Photos")) { try TarMember.plan(for: [a, b]) }
    }

    @Test func missingSourcesAreRejected() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(throws: EpocharyError.sourceMissing(missing)) { try TarMember.plan(for: [missing]) }
    }

    @Test func tarArgumentsStoreEachItemUnderItsOwnName() {
        let members = [TarMember(parent: URL(fileURLWithPath: "/Users/me/Documents"), name: "Taxes"),
                       TarMember(parent: URL(fileURLWithPath: "/Volumes/Disk"), name: "-odd")]
        let arguments = CommandLines.tar(members: members, excludeFinderMetadata: true)
        #expect(arguments == ["--create", "--file=-", "--format=pax", "--sort=name", "--numeric-owner",
                              "--exclude=.DS_Store",
                              "--directory=/Users/me/Documents", "Taxes",
                              "--directory=/Volumes/Disk", "./-odd"])
    }

    @Test func zstdArgumentsEnableUltraAboveLevel19() {
        #expect(CommandLines.zstdCompress(level: 19, longWindow: true) == ["-19", "--long=31", "-T0", "--no-progress", "-c", "-"])
        #expect(CommandLines.zstdCompress(level: 22, longWindow: false).prefix(2) == ["--ultra", "-22"])
    }

    @Test func publicKeyHeuristics() {
        #expect(Recipient.looksLikePublicKey("age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"))
        #expect(Recipient.looksLikePublicKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample me@host"))
        #expect(!Recipient.looksLikePublicKey("AGE-SECRET-KEY-1QQQ"))
        #expect(!Recipient.looksLikePublicKey("age1short"))
    }

    @Test func destinationInsideASourceIsRejected() throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Archives"), withIntermediateDirectories: true)
        let layout = ArchiveLayout(name: "x", destinationDirectory: source.appendingPathComponent("Archives"))
        #expect(throws: EpocharyError.destinationInsideSource(source: source)) {
            try ArchivePipeline.checkDestination(layout, sources: [source])
        }
        let sibling = ArchiveLayout(name: "x", destinationDirectory: root.url)
        try ArchivePipeline.checkDestination(sibling, sources: [source])
    }
}

/// A uniquely named directory removed when the value is deallocated.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpocharyTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
