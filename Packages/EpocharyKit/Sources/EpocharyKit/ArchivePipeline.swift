import CryptoKit
import Foundation

public struct ArchiveProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case preparing, archiving, finishingSegment, waitingForNextSegment, finishing, creatingParity, done
    }

    public var stage: Stage
    /// Bytes of the uncompressed tar stream read so far.
    public var bytesRead: Int64 = 0
    /// Total size of the source files; the tar stream is slightly larger.
    public var estimatedTotal: Int64 = 0
    /// Bytes of the encrypted archive written so far.
    public var bytesWritten: Int64 = 0
    public var parityFraction: Double?
    /// The segment being written, when splitting.
    public var currentSegment: Int?
    /// An upper bound on the number of segments, when splitting.
    public var estimatedSegments: Int?
    /// The finished segment waiting for confirmation, when pausing after each.
    public var waitingSegment: CompletedSegment?

    public init(stage: Stage) {
        self.stage = stage
    }

    public var fraction: Double? {
        switch stage {
        case .archiving:
            estimatedTotal > 0 ? min(Double(bytesRead) / Double(estimatedTotal), 0.99) : nil
        case .creatingParity, .finishingSegment: parityFraction
        case .done: 1
        case .preparing, .finishing, .waitingForNextSegment: nil
        }
    }
}

public struct SourceStats: Sendable, Hashable {
    public var files: Int = 0
    public var bytes: Int64 = 0

    public init(files: Int = 0, bytes: Int64 = 0) {
        self.files = files
        self.bytes = bytes
    }

    /// Counts regular files and their sizes without following symlinks.
    public static func measure(_ urls: [URL]) -> SourceStats {
        var stats = SourceStats()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        func add(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            stats.files += 1
            stats.bytes += Int64(values.fileSize ?? 0)
        }
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                add(url)
                continue
            }
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                            options: [], errorHandler: { _, _ in true })
            while let item = enumerator?.nextObject() as? URL { add(item) }
        }
        return stats
    }
}

public struct ArchiveResult: Sendable {
    public let layout: ArchiveLayout
    public let files: [URL]
    public let sourceStats: SourceStats
    public let tarBytes: Int64
    public let encryptedBytes: Int64
    public let compressedSHA256: String
    public let encryptedSHA256: String
    public let warnings: [String]
    public let duration: TimeInterval
    /// Empty unless the archive was split.
    public let segments: [CompletedSegment]
    /// Files that changed or disappeared while being archived.
    public let changes: [SourceChange]
}

/// Streams sources through tar → zstd → age into a new archive folder, hashing the
/// compressed and encrypted streams in-process so no plaintext ever touches the disk.
///
///     gtar ──▶ relay ──▶ zstd ──▶ relay (SHA-256) ──▶ age ──▶ relay (SHA-256) ──▶ .tar.zst.age
///                                   └──▶ zstd -d ──▶ gtar --list   (verification)
public struct ArchivePipeline: Sendable {
    public var tools: ToolLocator
    public var appVersion: String

    public init(tools: ToolLocator = ToolLocator(), appVersion: String = "dev") {
        self.tools = tools
        self.appVersion = appVersion
    }

    /// - Parameter confirmNextSegment: called after each segment except the last when
    ///   pausing after each segment; the next segment is written once it returns.
    public func run(_ request: ArchiveRequest,
                    progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in },
                    confirmNextSegment: @escaping @Sendable (CompletedSegment) async throws -> Void = { _ in })
        async throws -> ArchiveResult {
        let started = Date()
        // Sleep would stall the helper processes and drop network shares mid-archive.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Creating an archive")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let reporter = ProgressReporter(handler: progress)
        reporter.update { $0.stage = .preparing }

        try ArchiveLayout.validateName(request.name)
        guard !request.recipients.isEmpty else { throw EpocharyError.noRecipients }
        let members = try TarMember.plan(for: request.sources)
        let executables = Executables(
            tar: try tools.require(.tar),
            zstd: try tools.require(.zstd),
            age: try tools.require(.age),
            par2: request.parityPercent == nil ? nil : try tools.require(.par2))
        let layout = ArchiveLayout(name: request.name, destinationDirectory: request.destinationDirectory)
        try Self.checkDestination(layout, sources: request.sources)
        let volume = DestinationVolume(containing: request.destinationDirectory)
        if request.segmentation != nil, volume?.isTape == true {
            throw EpocharyError.destinationIsTape(request.destinationDirectory)
        }

        let stats = SourceStats.measure(request.sources)
        let space = SpaceRequirement(for: request, stats: stats)
        if space.isExact, let available = volume?.availableCapacity, available < space.bytes {
            throw EpocharyError.notEnoughSpace(needed: space.bytes, available: available)
        }
        var versions: [Tool: String] = [:]
        for tool in [Tool.tar, .zstd, .age] + (request.parityPercent == nil ? [] : [.par2]) {
            versions[tool] = await tools.version(of: tool)
        }
        let readme = ArchiveReadme(layout: layout, request: request, stats: stats, toolVersions: versions,
                                   appVersion: appVersion, created: started)
        let segmentation = request.segmentation.map { options in
            (options, SegmentOptions.estimatedCount(size: options.size, stats: stats))
        }
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: layout.folder, withIntermediateDirectories: false)
        do {
            reporter.update {
                $0.stage = .archiving
                $0.estimatedTotal = stats.bytes
                $0.estimatedSegments = segmentation?.1
            }
            let naming = segmentation.map { SegmentNaming(layout: layout, estimatedCount: $0.1) }
            let stream = try await Self.stream(request, members: members, layout: layout, naming: naming,
                                               readme: readme, executables: executables, reporter: reporter,
                                               confirmNextSegment: confirmNextSegment)
            try Task.checkCancellation()

            reporter.update { $0.stage = .finishing }
            let checksums = [
                (layout.compressedChecksum,
                 ArchiveLayout.checksumLine(hexDigest: stream.compressedSHA256, fileName: layout.compressedFileName)),
                (layout.encryptedChecksum,
                 ArchiveLayout.checksumLine(hexDigest: stream.encryptedSHA256, fileName: layout.encryptedFileName)),
            ]
            for (url, line) in checksums { try line.write(to: url, atomically: true, encoding: .utf8) }

            var changesFile: Data?
            if !stream.changes.isEmpty {
                changesFile = try await Self.encryptedChangeList(stream.changes, layout: layout, request: request,
                                                                 age: executables.age)
                try changesFile?.write(to: layout.changesFile)
            }

            if naming == nil, let percent = request.parityPercent, let par2 = executables.par2 {
                reporter.update { $0.stage = .creatingParity }
                try await Self.createParity(percent: percent, folder: layout.folder,
                                            fileName: layout.encryptedFileName, par2: par2, reporter: reporter)
            }

            let finalReadme = readme.render(ArchiveReadme.Outcome(
                tarBytes: stream.tarBytes, encryptedBytes: stream.encryptedBytes,
                compressedSHA256: stream.compressedSHA256, encryptedSHA256: stream.encryptedSHA256,
                segments: stream.segments, naming: naming, changes: stream.changes))
            try finalReadme.write(to: layout.readme, atomically: true, encoding: .utf8)
            // The last segment's medium carries the complete picture.
            if let last = stream.segments.last {
                try finalReadme.write(to: last.folder.appendingPathComponent(layout.readme.lastPathComponent),
                                      atomically: true, encoding: .utf8)
                for (url, line) in checksums {
                    try line.write(to: last.folder.appendingPathComponent(url.lastPathComponent),
                                   atomically: true, encoding: .utf8)
                }
                try changesFile?.write(to: last.folder.appendingPathComponent(layout.changesFileName))
            }

            let files = try FileManager.default
                .contentsOfDirectory(at: layout.folder, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            reporter.update { $0.stage = .done }
            return ArchiveResult(layout: layout, files: files, sourceStats: stats,
                                 tarBytes: stream.tarBytes, encryptedBytes: stream.encryptedBytes,
                                 compressedSHA256: stream.compressedSHA256,
                                 encryptedSHA256: stream.encryptedSHA256,
                                 warnings: stream.warnings, duration: Date().timeIntervalSince(started),
                                 segments: stream.segments, changes: stream.changes)
        } catch {
            try? FileManager.default.removeItem(at: layout.folder)
            throw error
        }
    }

    static func checkDestination(_ layout: ArchiveLayout, sources: [URL]) throws {
        var isDirectory: ObjCBool = false
        let destination = layout.folder.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EpocharyError.destinationMissing(destination)
        }
        if (try? FileManager.default.attributesOfItem(atPath: layout.folder.path)) != nil {
            throw EpocharyError.destinationExists(layout.folder)
        }
        let folderPath = destination.resolvingSymlinksInPath().appendingPathComponent(layout.name).path
        for source in sources {
            let sourcePath = source.resolvingSymlinksInPath().path
            if folderPath.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/") {
                throw EpocharyError.destinationInsideSource(source: source)
            }
        }
    }

    // MARK: - Streaming

    struct Executables {
        let tar: URL
        let zstd: URL
        let age: URL
        let par2: URL?
    }

    struct StreamOutcome {
        let tarBytes: Int64
        let encryptedBytes: Int64
        let compressedSHA256: String
        let encryptedSHA256: String
        let warnings: [String]
        let segments: [CompletedSegment]
        let changes: [SourceChange]
    }

    static func stream(_ request: ArchiveRequest, members: [TarMember], layout: ArchiveLayout,
                       naming: SegmentNaming?, readme: ArchiveReadme, executables: Executables,
                       reporter: ProgressReporter,
                       confirmNextSegment: @escaping @Sendable (CompletedSegment) async throws -> Void)
        async throws -> StreamOutcome {
        let tar = RunningProcess(name: "gtar", executable: executables.tar,
                                 arguments: CommandLines.tar(members: members,
                                                             excludeFinderMetadata: request.excludeFinderMetadata))
        let compressor = RunningProcess(name: "zstd", executable: executables.zstd,
                                        arguments: CommandLines.zstdCompress(level: request.compressionLevel,
                                                                             longWindow: request.longWindow))
        let encryptor = RunningProcess(name: "age", executable: executables.age,
                                       arguments: CommandLines.age(recipients: request.recipients))
        let tester = request.verify
            ? RunningProcess(name: "zstd-test", executable: executables.zstd,
                             arguments: CommandLines.zstdTest(longWindow: request.longWindow))
            : nil
        let lister = request.verify
            ? RunningProcess(name: "gtar-list", executable: executables.tar, arguments: CommandLines.tarList)
            : nil

        let tarOut = Pipe(), compressIn = Pipe(), compressOut = Pipe(), encryptIn = Pipe(), encryptOut = Pipe()
        tar.process.standardInput = FileHandle.nullDevice
        tar.process.standardOutput = tarOut
        compressor.process.standardInput = compressIn
        compressor.process.standardOutput = compressOut
        encryptor.process.standardInput = encryptIn
        encryptor.process.standardOutput = encryptOut
        var testIn: Pipe?
        if let tester, let lister {
            let input = Pipe(), decompressed = Pipe()
            tester.process.standardInput = input
            tester.process.standardOutput = decompressed
            lister.process.standardInput = decompressed
            lister.process.standardOutput = FileHandle.nullDevice
            testIn = input
        }

        let output: any ByteSink
        var segmented: SegmentedOutput?
        if let naming, let options = request.segmentation {
            segmented = segmentedOutput(naming: naming, options: options, request: request, readme: readme,
                                        par2: executables.par2, reporter: reporter, confirm: confirmNextSegment)
            output = segmented!
        } else {
            guard FileManager.default.createFile(atPath: layout.encryptedArchive.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: layout.encryptedArchive.path])
            }
            output = HandleSink(handle: try FileHandle(forWritingTo: layout.encryptedArchive), synchronize: true)
        }
        let compressedDestinations: [any ByteSink] = [HandleSink(handle: encryptIn.fileHandleForWriting)]
            + [testIn.map { HandleSink(handle: $0.fileHandleForWriting) }].compactMap { $0 }
        let segmentedOutput = segmented

        // Downstream first, so every reader exists before its writer starts.
        let processes = [encryptor, compressor, tester, lister, tar].compactMap { $0 }
        let terminateAll: @Sendable () -> Void = {
            processes.forEach { $0.terminate() }
            segmentedOutput?.cancel()
        }
        let monitor = ChangeMonitor()
        tar.onStderrLine = { line in
            if monitor.record(line) != nil, request.stopOnSourceChange, !monitor.didStop {
                monitor.markStopped()
                terminateAll()
            }
        }
        do {
            for process in processes { try process.start() }
        } catch {
            terminateAll()
            output.abort()
            throw error
        }

        return try await withTaskCancellationHandler {
            async let tarRelay = relay(from: tarOut.fileHandleForReading,
                                       to: [HandleSink(handle: compressIn.fileHandleForWriting)],
                                       hashing: false, onFailure: terminateAll) { count in
                reporter.update(force: false) { $0.bytesRead += Int64(count) }
            }
            async let compressedRelay = relay(from: compressOut.fileHandleForReading,
                                              to: compressedDestinations,
                                              hashing: true, onFailure: terminateAll) { _ in }
            async let encryptedRelay = relay(from: encryptOut.fileHandleForReading, to: [output],
                                             hashing: true, onFailure: terminateAll) { count in
                reporter.update(force: false) { $0.bytesWritten += Int64(count) }
            }
            let relays = await (tar: tarRelay, compressed: compressedRelay, encrypted: encryptedRelay)

            var terminations: [ObjectIdentifier: RunningProcess.Termination] = [:]
            for process in processes {
                terminations[ObjectIdentifier(process)] = await process.waitForExit()
            }
            try Task.checkCancellation()
            if monitor.didStop, let change = monitor.changes.first {
                throw EpocharyError.sourceChanged(change)
            }

            // The root cause is the process that failed on its own; the ones Epochary
            // stopped afterwards, or that only saw a broken pipe, are side effects.
            var warnings: [String] = []
            for process in [encryptor, compressor, tester, lister, tar].compactMap({ $0 }) {
                guard let termination = terminations[ObjectIdentifier(process)],
                      termination.exitedNormally, !process.wasTerminatedByRequest else { continue }
                // Exit status 1 is tar reporting that files changed; the monitor has the details.
                if process === tar, termination.status == 0 || termination.status == 1 {
                    warnings += monitor.warnings
                    if termination.status == 1, monitor.changes.isEmpty { warnings.append(process.stderrText) }
                    continue
                }
                if termination.status == 0 { continue }
                if process === tester || process === lister {
                    throw EpocharyError.verificationFailed(process.stderrText)
                }
                let tool: Tool = process === encryptor ? .age : process === compressor ? .zstd : .tar
                throw EpocharyError.processFailed(tool, status: termination.status, message: process.stderrText)
            }
            if processes.contains(where: { terminations[ObjectIdentifier($0)]?.exitedNormally != true }) {
                // Something was killed without a process reporting why; surface the relay
                // error, preferring the cause over the broken pipes it left behind.
                let errors = [relays.tar, relays.compressed, relays.encrypted].compactMap { relay -> Error? in
                    if case .failure(let error) = relay { return error } else { return nil }
                }
                if let error = errors.first(where: { !isBrokenPipe($0) }) ?? errors.first { throw error }
                throw EpocharyError.verificationFailed("A helper process stopped unexpectedly.")
            }

            let tarOutput = try relays.tar.get()
            let compressedOutput = try relays.compressed.get()
            let encryptedOutput = try relays.encrypted.get()
            return StreamOutcome(tarBytes: tarOutput.bytes, encryptedBytes: encryptedOutput.bytes,
                                 compressedSHA256: compressedOutput.sha256 ?? "",
                                 encryptedSHA256: encryptedOutput.sha256 ?? "",
                                 warnings: warnings, segments: segmentedOutput?.segments ?? [],
                                 changes: monitor.changes)
        } onCancel: {
            terminateAll()
        }
    }

    static func isBrokenPipe(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPIPE) { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map(isBrokenPipe) ?? false
    }

    struct RelayOutput: Sendable {
        let bytes: Int64
        let sha256: String?
    }

    /// Copies one pipe to one or more destinations, hashing what passes through.
    /// Destinations are closed at the end either way, so downstream readers see EOF.
    static func relay(from source: FileHandle, to destinations: [any ByteSink], hashing: Bool,
                      onFailure: @escaping @Sendable () -> Void,
                      onChunk: @escaping @Sendable (Int) -> Void) async -> Result<RelayOutput, Error> {
        do {
            return .success(try await onDedicatedThread("relay") {
                var hasher = SHA256()
                var total: Int64 = 0
                do {
                    while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                        if hashing { hasher.update(data: chunk) }
                        for destination in destinations { try destination.write(chunk) }
                        total += Int64(chunk.count)
                        onChunk(chunk.count)
                    }
                    for destination in destinations { try destination.finish() }
                    try? source.close()
                } catch {
                    onFailure()
                    for destination in destinations { destination.abort() }
                    try? source.close()
                    throw error
                }
                return RelayOutput(bytes: total, sha256: hashing ? hasher.finalize().hexString : nil)
            })
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Segments

    static func segmentedOutput(naming: SegmentNaming, options: SegmentOptions, request: ArchiveRequest,
                                readme: ArchiveReadme, par2: URL?, reporter: ProgressReporter,
                                confirm: @escaping @Sendable (CompletedSegment) async throws -> Void) -> SegmentedOutput {
        SegmentedOutput(naming: naming, options: options) { segment in
            try readme.renderSegment(segment, naming: naming)
                .write(to: segment.folder.appendingPathComponent(readme.layout.readme.lastPathComponent),
                       atomically: true, encoding: .utf8)
            if let percent = request.parityPercent, let par2 {
                // Writing straight through, earlier segments are finished in the background.
                if options.pauseAfterEach {
                    reporter.update {
                        $0.stage = .finishingSegment
                        $0.parityFraction = nil
                    }
                }
                try await createParity(percent: percent, folder: segment.folder,
                                       fileName: segment.file.lastPathComponent, par2: par2, reporter: reporter)
            }
        } confirm: { segment in
            reporter.update {
                $0.stage = .waitingForNextSegment
                $0.waitingSegment = segment
            }
            try await confirm(segment)
            reporter.update {
                $0.stage = .archiving
                $0.waitingSegment = nil
            }
        } onSegmentStarted: { number in
            reporter.update { $0.currentSegment = number }
        } onFinishing: {
            reporter.update {
                $0.stage = request.parityPercent == nil ? .finishing : .creatingParity
                $0.parityFraction = nil
            }
        }
    }

    // MARK: - Changes

    /// The changed-file list holds file names, which are never stored in plain text,
    /// so it's encrypted to the archive's recipients.
    static func encryptedChangeList(_ changes: [SourceChange], layout: ArchiveLayout, request: ArchiveRequest,
                                    age: URL) async throws -> Data {
        let lines = changes.map { "\($0.kind.rawValue)\t\($0.path)" }.joined(separator: "\n")
        let text = """
        Files and folders that changed or disappeared while the archive \(layout.name) was being made.
        Paths are as stored in the archive. changed: the archived copy may mix old and new contents.
        removed: missing from the archive. shrank: the archived copy is padded with zeros.

        \(lines)

        """
        let result = try await ProcessRunner.capture(age, arguments: CommandLines.age(recipients: request.recipients),
                                                     stdin: Data(text.utf8))
        guard result.status == 0 else {
            throw EpocharyError.processFailed(.age, status: result.status, message: result.stderr)
        }
        return result.stdoutData
    }

    // MARK: - Parity

    static func createParity(percent: Int, folder: URL, fileName: String, par2: URL,
                             reporter: ProgressReporter) async throws {
        let process = RunningProcess(name: "par2", executable: par2,
                                     arguments: CommandLines.par2(percent: percent, fileName: fileName),
                                     workingDirectory: folder)
        let stdout = Pipe()
        process.process.standardInput = FileHandle.nullDevice
        process.process.standardOutput = stdout
        try process.start()

        try await withTaskCancellationHandler {
            // par2 rewrites a "Processing: 42.1%" line as it goes.
            let tail = try? await onDedicatedThread("par2.stdout") {
                var tail = ""
                let handle = stdout.fileHandleForReading
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    let text = String(decoding: chunk, as: UTF8.self)
                    tail = String((tail + text).suffix(2000))
                    if let match = text.matches(of: /(\d+(?:\.\d+)?)%/).last, let value = Double(match.1) {
                        reporter.update(force: false) { $0.parityFraction = min(value / 100, 1) }
                    }
                }
                return tail
            }
            let termination = await process.waitForExit()
            try Task.checkCancellation()
            guard termination.exitedNormally, termination.status == 0 else {
                let message = [process.stderrText, tail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                throw EpocharyError.processFailed(.par2, status: termination.status, message: message)
            }
        } onCancel: {
            process.terminate()
        }
    }
}

final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = ArchiveProgress(stage: .preparing)
    private var lastEmit = Date.distantPast
    private let handler: @Sendable (ArchiveProgress) -> Void

    init(handler: @escaping @Sendable (ArchiveProgress) -> Void) {
        self.handler = handler
    }

    /// Stage changes are always delivered; byte counts at most ten times a second.
    func update(force: Bool = true, _ change: (inout ArchiveProgress) -> Void) {
        let snapshot: ArchiveProgress? = lock.withLock {
            change(&state)
            let now = Date()
            guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return nil }
            lastEmit = now
            return state
        }
        if let snapshot { handler(snapshot) }
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
