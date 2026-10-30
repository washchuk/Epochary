import Foundation
import Testing
@testable import EpocharyKit

struct SourceChangeTests {
    @Test func parsesTarsChangeWarnings() {
        #expect(SourceChange.parse(tarMessage: "gtar: Photos/2024/a.jpg: file changed as we read it")
                == SourceChange(path: "Photos/2024/a.jpg", kind: .changed))
        #expect(SourceChange.parse(tarMessage: "gtar: Notes/z.txt: File removed before we read it")
                == SourceChange(path: "Notes/z.txt", kind: .removed))
        #expect(SourceChange.parse(tarMessage: "gtar: log.txt: File shrank by 120 bytes; padding with zeros")
                == SourceChange(path: "log.txt", kind: .shrank))
        #expect(SourceChange.parse(tarMessage: "gtar: Odd: name.txt: file changed as we read it")?.path == "Odd: name.txt")
        #expect(SourceChange.parse(tarMessage: "gtar: data/sock: socket ignored") == nil)
        #expect(SourceChange.parse(tarMessage: "gtar: Exiting with failure status due to previous errors") == nil)
    }
}

@Suite(.enabled(if: Tool.allCases.allSatisfy { ToolLocator().locate($0) != nil }, "gtar, zstd, age and par2 must be installed"))
struct SourceChangeIntegrationTests {
    let tools = ToolLocator()

    @Test func stopsAsSoonAsAFileChanges() async throws {
        let root = try TemporaryDirectory()
        let (request, _, late) = try await liveRequest(in: root, stop: true)
        await #expect {
            try await ArchivePipeline(tools: tools).run(request) { _ in } confirmNextSegment: { segment in
                if segment.number == 1 { try FileManager.default.removeItem(at: late) }
            }
        } throws: { error in
            error as? EpocharyError == .sourceChanged(SourceChange(path: "data/z.txt", kind: .removed))
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("live").path))
    }

    @Test func reportsChangesWithoutLeakingNames() async throws {
        let root = try TemporaryDirectory()
        let (request, keyFile, late) = try await liveRequest(in: root, stop: false)
        let result = try await ArchivePipeline(tools: tools).run(request) { _ in } confirmNextSegment: { segment in
            if segment.number == 1 { try FileManager.default.removeItem(at: late) }
        }

        #expect(result.changes.contains(SourceChange(path: "data/z.txt", kind: .removed)))
        #expect(result.warnings.isEmpty, "change messages are reported as changes, not warnings")
        let list = try shell("age -d -i \(keyFile.path.quoted) live.changes.txt.age", in: result.layout.folder)
        #expect(list.contains("removed\tdata/z.txt"))
        let last = try #require(result.segments.last)
        #expect(FileManager.default.fileExists(atPath: last.folder.appendingPathComponent("live.changes.txt.age").path))

        let readme = try String(contentsOf: result.layout.readme, encoding: .utf8)
        #expect(readme.contains("CONSISTENCY"))
        #expect(readme.contains("is not a consistent copy"))
        #expect(readme.contains("age -d -i key.txt live.changes.txt.age"))
        #expect(!readme.contains("z.txt"))
        #expect(!readme.contains("a.bin"))
    }

    @Test func unchangedArchiveSaysSo() async throws {
        let root = try TemporaryDirectory()
        let (request, _, _) = try await liveRequest(in: root, stop: true)
        let result = try await ArchivePipeline(tools: tools).run(request)
        #expect(result.changes.isEmpty)
        let readme = try String(contentsOf: result.layout.readme, encoding: .utf8)
        #expect(readme.contains("GNU tar reported no files changing"))
        #expect(!FileManager.default.fileExists(atPath: result.layout.changesFile.path))
    }

    /// A folder whose big first file keeps tar busy past the first segment, so a later
    /// file can be removed before tar reaches it.
    private func liveRequest(in root: TemporaryDirectory, stop: Bool) async throws -> (ArchiveRequest, URL, URL) {
        let source = root.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data((0..<20_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: source.appendingPathComponent("a.bin"))
        let late = source.appendingPathComponent("z.txt")
        try "late\n".write(to: late, atomically: true, encoding: .utf8)
        let keyFile = root.url.appendingPathComponent("key.txt")
        let publicKey = try await KeyGenerator.generateIdentity(at: keyFile, postQuantum: false, tools: tools)
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "live",
                                     recipients: [Recipient(label: "", publicKey: publicKey)],
                                     compressionLevel: 1, longWindow: false,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: true),
                                     stopOnSourceChange: stop)
        return (request, keyFile, late)
    }
}

@Suite(.enabled(if: Tool.allCases.allSatisfy { ToolLocator().locate($0) != nil }, "gtar, zstd, age and par2 must be installed"))
struct FailureReportingTests {
    struct Interrupted: Error, Equatable {}

    /// A failure in the middle of the pipeline is reported as itself, not as the
    /// broken pipes it causes upstream.
    @Test func reportsTheCauseNotTheBrokenPipe() async throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("data.bin")
        try Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)
        let publicKey = try await KeyGenerator.generateIdentity(at: root.url.appendingPathComponent("key.txt"),
                                                                postQuantum: false, tools: ToolLocator())
        let request = ArchiveRequest(sources: [source], destinationDirectory: root.url, name: "x",
                                     recipients: [Recipient(label: "", publicKey: publicKey)], compressionLevel: 1,
                                     segmentation: SegmentOptions(size: 1 << 20, pauseAfterEach: true))
        await #expect(throws: Interrupted.self) {
            try await ArchivePipeline(tools: ToolLocator()).run(request) { _ in } confirmNextSegment: { _ in
                throw Interrupted()
            }
        }
    }
}
