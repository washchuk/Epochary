import Foundation
import Testing
@testable import EpocharyKit

struct DestinationTests {
    @Test(arguments: [
        ("ltfs", "/dev/rmt0", nil, true),
        ("macfuse", "ltfs@/dev/rmt1", nil, true),
        ("osxfuse", "fuse-ltfs", "macFUSE Volume", true),
        ("macfuse", "TAPE01", "LTFS", true),
        ("apfs", "/dev/disk3s5", "APFS", false),
        ("smbfs", "//archive@nas.local/Staging", "SMB (Server Message Block)", false),
        ("exfat", "/dev/disk6s1", "ExFAT", false),
        ("hfs", "/dev/disk7s2", "Mac OS Extended (Journaled)", false),
    ] as [(String, String, String?, Bool)])
    func tapesAreRecognised(type: String, from: String, description: String?, isTape: Bool) {
        let volume = DestinationVolume(fileSystemType: type, mountedFrom: from, formatDescription: description,
                                       availableCapacity: nil)
        #expect(volume.isTape == isTape)
    }

    @Test func readsTheRealVolume() throws {
        let root = try TemporaryDirectory()
        let volume = try #require(DestinationVolume(containing: root.url))
        #expect(volume.fileSystemType == "apfs")
        #expect((volume.availableCapacity ?? 0) > 0)
        #expect(!volume.isTape)
    }

    @Test func oneSegmentAtATimeNeedsExactlyOneSegment() {
        let stats = SourceStats(files: 1000, bytes: 50_000_000_000_000)
        var request = ArchiveRequest(sources: [], destinationDirectory: URL(fileURLWithPath: "/tmp"), name: "x",
                                     recipients: [], parityPercent: 10,
                                     segmentation: SegmentOptions(size: 1_000_000_000_000, pauseAfterEach: true))
        let paused = SpaceRequirement(for: request, stats: stats)
        #expect(paused.isExact)
        #expect(paused.bytes == 1_100_000_000_000 + (2 << 20) + (1 << 20))

        request.segmentation?.pauseAfterEach = false
        let all = SpaceRequirement(for: request, stats: stats)
        #expect(!all.isExact)
        #expect(all.bytes > 55_000_000_000_000)

        request.segmentation = nil
        request.parityPercent = nil
        #expect(SpaceRequirement(for: request, stats: stats).bytes > stats.bytes)
    }
}

@Suite(.enabled(if: Tool.allCases.allSatisfy { ToolLocator().locate($0) != nil }, "gtar, zstd, age and par2 must be installed"))
struct DestinationIntegrationTests {
    let tools = ToolLocator()

    @Test func refusesWhenOneSegmentCantFit() async throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("data.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        // A petabyte segment can't fit on this Mac's disk.
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "huge",
                                     recipients: [Recipient(label: "", publicKey: publicKey)],
                                     segmentation: SegmentOptions(size: 1 << 50, pauseAfterEach: true))
        await #expect {
            try await ArchivePipeline(tools: tools).run(request)
        } throws: { error in
            guard case EpocharyError.notEnoughSpace = error else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("huge").path))
    }

    @Test func keepsTheMacAwakeWhileArchiving() async throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("data.bin")
        try Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "awake",
                                     recipients: [Recipient(label: "", publicKey: publicKey)], compressionLevel: 1,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: true))
        let assertions = LockedBox("")
        let directory = root.url
        _ = try await ArchivePipeline(tools: tools).run(request) { _ in } confirmNextSegment: { _ in
            if assertions.value.isEmpty {
                assertions.value = (try? shell("pmset -g assertions", in: directory)) ?? ""
            }
        }
        #expect(assertions.value.contains("PreventUserIdleSystemSleep"))
        // Named, since other tests' archives may be running at the same time.
        #expect(assertions.value.contains("Creating the archive \"awake\""))
        let after = try shell("pmset -g assertions", in: root.url)
        #expect(!after.contains("Creating the archive \"awake\""))
    }
}
