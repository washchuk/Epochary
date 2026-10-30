import CryptoKit
import Foundation
import Testing
@testable import EpocharyKit

struct SegmentTests {
    @Test(arguments: [nil, 3, 5, 10] as [Int?])
    func segmentAndItsRecoveryDataFitTheMedium(parity: Int?) throws {
        let capacity: Int64 = 12_000_000_000_000  // LTO-8
        let size = try #require(SegmentOptions.segmentSize(forCapacity: capacity, parityPercent: parity))
        // par2 writes its percentage plus about 1.5 MB of fixed overhead.
        let parityBytes = Int64(Double(size) * Double(parity ?? 0) / 100) + (2 << 20)
        #expect(size + parityBytes + (1 << 20) <= Int64(Double(capacity) * (1 - SegmentOptions.headroom)))
        #expect(size > Int64(Double(capacity) * 0.85 / (1 + Double(parity ?? 0) / 100)))
        #expect(size % (1 << 20) == 0)
    }

    @Test func tinyMediaAreRejected() {
        #expect(SegmentOptions.segmentSize(forCapacity: 50 << 20, parityPercent: 10) == nil)
    }

    @Test func namesSortAndGlobInOrder() {
        let layout = ArchiveLayout(name: "tapes", destinationDirectory: URL(fileURLWithPath: "/tmp"))
        let naming = SegmentNaming(layout: layout, estimatedCount: 12)
        #expect(naming.fileName(7) == "tapes.tar.zst.age.007")
        #expect(naming.folder(7).lastPathComponent == "tapes-segment-007")
        #expect(naming.glob == "tapes.tar.zst.age.[0-9][0-9][0-9]")
        #expect(SegmentNaming(layout: layout, estimatedCount: 12_345).fileName(7) == "tapes.tar.zst.age.00007")
    }

    @Test func estimateIsAnUpperBound() {
        let stats = SourceStats(files: 10, bytes: 10 << 20)
        // 10 MiB of data plus tar headers and stream overhead can never need fewer than 11.
        #expect((11...12).contains(SegmentOptions.estimatedCount(size: 1 << 20, stats: stats)))
    }

    /// A stream that ends exactly on a boundary must not leave an empty last segment,
    /// and writes may straddle boundaries.
    @Test func streamSplitsAtExactBoundaries() throws {
        let root = try TemporaryDirectory()
        let layout = ArchiveLayout(name: "x", destinationDirectory: root.url)
        try FileManager.default.createDirectory(at: layout.folder, withIntermediateDirectories: false)
        let finished = LockedBox<[Int]>([])
        let output = SegmentedOutput(naming: SegmentNaming(layout: layout, estimatedCount: 3),
                                     options: SegmentOptions(size: 1000, pauseAfterEach: false),
                                     finishSegment: { finished.value.append($0.number) },
                                     confirm: { _ in Issue.record("no confirmation when writing straight through") },
                                     onSegmentStarted: { _ in }, onFinishing: {})
        let data = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) })
        for chunk in stride(from: 0, to: data.count, by: 700) {
            try output.write(data[chunk..<min(chunk + 700, data.count)])
        }
        try output.finish()

        #expect(output.segments.map(\.bytes) == [1000, 1000, 1000])
        #expect(finished.value == [1, 2, 3])
        var joined = Data()
        for segment in output.segments {
            let bytes = try Data(contentsOf: segment.file)
            #expect(SHA256.hash(data: bytes).hexString == segment.sha256)
            joined += bytes
        }
        #expect(joined == data)
        #expect(!FileManager.default.fileExists(atPath: layout.folder.appendingPathComponent("x-segment-004").path))
    }
}

@Suite(.enabled(if: Tool.allCases.allSatisfy { ToolLocator().locate($0) != nil }, "gtar, zstd, age and par2 must be installed"))
struct SegmentIntegrationTests {
    let tools = ToolLocator()

    @Test func writingAllSegmentsRestoresFromTheJoinedFiles() async throws {
        let root = try TemporaryDirectory()
        let (source, keyFile, publicKey) = try await setUp(in: root)
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "tapes",
                                     recipients: [Recipient(label: "", publicKey: publicKey)], compressionLevel: 3,
                                     parityPercent: 10,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: false))
        let result = try await ArchivePipeline(tools: tools).run(request)

        #expect(result.segments.count == 4)
        #expect(result.segments.dropLast().allSatisfy { $0.bytes == 1 << 20 })
        #expect(result.segments.map(\.bytes).reduce(0, +) == result.encryptedBytes)
        for segment in result.segments {
            let name = segment.file.lastPathComponent
            try shell("shasum -a 256 -c \(name).sha256", in: segment.folder)
            try shell("par2 verify -q \(name).par2", in: segment.folder)
            #expect(FileManager.default.fileExists(atPath: segment.folder.appendingPathComponent("tapes.README.txt").path))
        }
        let last = try #require(result.segments.last)
        let finalReadme = try String(contentsOf: last.folder.appendingPathComponent("tapes.README.txt"), encoding: .utf8)
        #expect(finalReadme == (try String(contentsOf: result.layout.readme, encoding: .utf8)))
        #expect(finalReadme.contains("split into 4 segments"))
        for segment in result.segments { #expect(finalReadme.contains(segment.sha256)) }
        let firstReadme = try String(contentsOf: result.segments[0].folder.appendingPathComponent("tapes.README.txt"), encoding: .utf8)
        #expect(firstReadme.contains("SEGMENT 1"))

        // Restore exactly as the README says: all segment files in one folder, joined by glob.
        let gathered = root.url.appendingPathComponent("gathered")
        try FileManager.default.createDirectory(at: gathered, withIntermediateDirectories: true)
        for segment in result.segments.reversed() {
            try FileManager.default.copyItem(at: segment.file, to: gathered.appendingPathComponent(segment.file.lastPathComponent))
        }
        let joinedHash = try shell("cat tapes.tar.zst.age.[0-9][0-9][0-9] | shasum -a 256 | cut -d' ' -f1", in: gathered)
        #expect(joinedHash == result.encryptedSHA256)
        try restoreAndCompare(gathered: gathered, keyFile: keyFile, source: source, root: root)
    }

    @Test func pausingAfterEachSegmentLetsItBeMovedAway() async throws {
        let root = try TemporaryDirectory()
        let (source, keyFile, publicKey) = try await setUp(in: root)
        let tape = root.url.appendingPathComponent("tape")
        try FileManager.default.createDirectory(at: tape, withIntermediateDirectories: true)
        let confirmed = LockedBox<[Int]>([])
        let stages = StageLog()
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "tapes",
                                     recipients: [Recipient(label: "", publicKey: publicKey)], compressionLevel: 3,
                                     parityPercent: 5,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: true))
        let result = try await ArchivePipeline(tools: tools).run(request) { stages.record($0.stage) } confirmNextSegment: { segment in
            // Everything for this medium is ready before we're asked to continue.
            let names = try FileManager.default.contentsOfDirectory(atPath: segment.folder.path)
            #expect(names.contains("\(segment.file.lastPathComponent).par2"))
            #expect(names.contains("\(segment.file.lastPathComponent).sha256"))
            #expect(names.contains("tapes.README.txt"))
            #expect(!FileManager.default.fileExists(atPath: segment.folder.deletingLastPathComponent()
                .appendingPathComponent("tapes-segment-\(String(format: "%03d", segment.number + 1))").path))
            // "Write it to tape", then free the disk space.
            try FileManager.default.copyItem(at: segment.folder, to: tape.appendingPathComponent(segment.folder.lastPathComponent))
            try FileManager.default.removeItem(at: segment.folder)
            confirmed.value.append(segment.number)
        }

        #expect(result.segments.count == 4)
        #expect(confirmed.value == [1, 2, 3], "no pause after the last segment")
        #expect(stages.stages.contains(.waitingForNextSegment))
        let last = try #require(result.segments.last)
        try FileManager.default.copyItem(at: last.folder, to: tape.appendingPathComponent(last.folder.lastPathComponent))

        let gathered = root.url.appendingPathComponent("gathered")
        try FileManager.default.createDirectory(at: gathered, withIntermediateDirectories: true)
        try shell("cp tapes-segment-*/tapes.tar.zst.age.[0-9][0-9][0-9] \(gathered.path.quoted)", in: tape)
        try restoreAndCompare(gathered: gathered, keyFile: keyFile, source: source, root: root)

        // Run the README's swap-media loop as printed, answering its prompts from /dev/null.
        let readme = try String(contentsOf: result.layout.readme, encoding: .utf8)
        let start = try #require(readme.range(of: "MEDIUM=/Volumes/MEDIUM"))
        let end = try #require(readme.range(of: "tar -xf - -C restored", range: start.upperBound..<readme.endIndex))
        let script = String(readme[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: "MEDIUM=/Volumes/MEDIUM", with: "MEDIUM=\(tape.path.quoted)")
            .replacingOccurrences(of: "key.txt", with: keyFile.path.quoted)
            .replacingOccurrences(of: "/dev/tty", with: "/dev/null")
        let work = root.url.appendingPathComponent("streamed")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try shell(script, in: work)
        try shell("diff -r \(source.path.quoted) restored/data", in: work)
    }

    @Test func cancellingWhilePausedRemovesEverything() async throws {
        let root = try TemporaryDirectory()
        let (source, _, publicKey) = try await setUp(in: root)
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "tapes",
                                     recipients: [Recipient(label: "", publicKey: publicKey)], compressionLevel: 3,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: true))
        let paused = LockedBox(false)
        let task = Task {
            try await ArchivePipeline(tools: tools).run(request) { _ in } confirmNextSegment: { _ in
                paused.value = true
                try await Task.sleep(for: .seconds(3600))
            }
        }
        while !paused.value { try await Task.sleep(for: .milliseconds(50)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("tapes").path))
    }

    private func setUp(in root: TemporaryDirectory) async throws -> (URL, URL, String) {
        let source = root.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data((0..<1_800_000).map { _ in UInt8.random(in: 0...255) }).write(to: source.appendingPathComponent("a.bin"))
        try Data((0..<1_700_000).map { _ in UInt8.random(in: 0...255) }).write(to: source.appendingPathComponent("sub/b.bin"))
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        return (source, keyFile, publicKey)
    }

    private func restoreAndCompare(gathered: URL, keyFile: URL, source: URL, root: TemporaryDirectory) throws {
        let restored = root.url.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        try shell("cat tapes.tar.zst.age.[0-9][0-9][0-9] | age -d -i \(keyFile.path.quoted) | zstd -d --long=31 | tar -xf - -C \(restored.path.quoted)", in: gathered)
        try shell("diff -r \(source.path.quoted) \(restored.appendingPathComponent("data").path.quoted)", in: root.url)
    }
}
