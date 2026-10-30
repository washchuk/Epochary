import CryptoKit
import Foundation

/// Splitting the encrypted archive into fixed-size segments, e.g. one per LTFS tape.
public struct SegmentOptions: Sendable, Equatable {
    /// Bytes of archive data per segment; the last one is usually shorter.
    public var size: Int64
    /// Wait for confirmation after each finished segment before writing the next, so it
    /// can be copied to its medium and deleted to free disk space.
    public var pauseAfterEach: Bool

    public init(size: Int64, pauseAfterEach: Bool) {
        self.size = size
        self.pauseAfterEach = pauseAfterEach
    }

    /// Space left free on each medium for its file system.
    public static let headroom = 0.03
    /// Room for par2's fixed overhead, the checksum files and the README.
    public static let reserve: Int64 = 64 << 20

    /// The largest segment that fits on a medium together with its recovery data,
    /// checksum and README, or nil if the medium is too small to be useful.
    public static func segmentSize(forCapacity capacity: Int64, parityPercent: Int?) -> Int64? {
        let usable = Double(capacity) * (1 - headroom) - Double(reserve)
        let size = Int64(usable / (1 + Double(parityPercent ?? 0) / 100))
        let mebibyte: Int64 = 1 << 20
        guard size >= mebibyte else { return nil }
        return size / mebibyte * mebibyte
    }

    /// An upper bound on the encrypted archive's size: tar adds headers and padding per
    /// file, and zstd and age add a little to data that doesn't compress.
    static func maximumArchiveSize(for stats: SourceStats) -> Int64 {
        let tar = stats.bytes + Int64(stats.files + 16) * 3072 + (1 << 20)
        return tar + tar / 1000
    }

    static func estimatedCount(size: Int64, stats: SourceStats) -> Int {
        Int((maximumArchiveSize(for: stats) + size - 1) / size)
    }
}

/// A segment that has been written, closed and checksummed.
public struct CompletedSegment: Sendable, Equatable {
    public let number: Int
    public let folder: URL
    public let file: URL
    public let bytes: Int64
    public let sha256: String
}

/// Names segments with a fixed number of digits so they sort and glob in order.
struct SegmentNaming: Sendable, Equatable {
    let layout: ArchiveLayout
    let width: Int

    init(layout: ArchiveLayout, estimatedCount: Int) {
        self.layout = layout
        self.width = max(3, String(estimatedCount).count)
    }

    func suffix(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    func folder(_ number: Int) -> URL {
        layout.folder.appendingPathComponent("\(layout.name)-segment-\(suffix(number))", isDirectory: true)
    }

    func fileName(_ number: Int) -> String {
        "\(layout.encryptedFileName).\(suffix(number))"
    }

    /// Matches every segment file and nothing else, in order.
    var glob: String { "\(layout.encryptedFileName)." + String(repeating: "[0-9]", count: width) }
}

/// Destination for a relay. Methods are called from the relay's thread.
protocol ByteSink: Sendable {
    func write(_ data: Data) throws
    /// Flushes and closes after the last write.
    func finish() throws
    /// Closes after a failure, without flushing.
    func abort()
}

struct HandleSink: ByteSink {
    let handle: FileHandle
    var synchronize = false

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }

    func finish() throws {
        if synchronize { try handle.synchronize() }
        try handle.close()
    }

    func abort() { try? handle.close() }
}

/// Writes the encrypted stream as a series of segment files, each in its own folder.
///
/// A full segment is only closed once more data arrives, so a stream that ends exactly
/// on a boundary doesn't produce an empty last segment. Closed segments are handed to
/// `finishSegment` (checksum, par2, README): in the background when writing straight
/// through, or before pausing for confirmation when pausing after each segment.
final class SegmentedOutput: ByteSink, @unchecked Sendable {
    typealias SegmentHandler = @Sendable (CompletedSegment) async throws -> Void

    let naming: SegmentNaming
    private let options: SegmentOptions
    private let finishSegment: SegmentHandler
    private let confirm: SegmentHandler
    private let onSegmentStarted: @Sendable (Int) -> Void
    private let onFinishing: @Sendable () -> Void

    private let lock = NSLock()
    private var handle: FileHandle?
    private var number = 0
    private var written: Int64 = 0
    private var hasher = SHA256()
    private var completed: [CompletedSegment] = []
    private var background: Task<Void, Error>?
    private var backgroundTasks: [Task<Void, Error>] = []
    private var bridged: Task<Void, Never>?
    private var isCancelled = false

    init(naming: SegmentNaming, options: SegmentOptions, finishSegment: @escaping SegmentHandler,
         confirm: @escaping SegmentHandler, onSegmentStarted: @escaping @Sendable (Int) -> Void,
         onFinishing: @escaping @Sendable () -> Void) {
        self.naming = naming
        self.options = options
        self.finishSegment = finishSegment
        self.confirm = confirm
        self.onSegmentStarted = onSegmentStarted
        self.onFinishing = onFinishing
    }

    var segments: [CompletedSegment] { lock.withLock { completed } }

    func write(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            if handle == nil || written == options.size {
                try startNextSegment()
            }
            let count = Int(min(options.size - written, Int64(data.endIndex - offset)))
            let slice = data[offset..<(offset + count)]
            try handle?.write(contentsOf: slice)
            hasher.update(data: slice)
            written += Int64(count)
            offset += count
        }
    }

    func finish() throws {
        guard handle != nil else { return }
        let last = try closeSegment()
        onFinishing()
        try runBlocking { [background, finishSegment] in
            try await background?.value
            try await finishSegment(last)
        }
    }

    func abort() {
        try? handle?.close()
        handle = nil
        cancel()
    }

    /// Stops background finishing and any wait for confirmation.
    func cancel() {
        lock.withLock {
            isCancelled = true
            backgroundTasks.forEach { $0.cancel() }
            bridged?.cancel()
        }
    }

    private func startNextSegment() throws {
        if handle != nil {
            let segment = try closeSegment()
            if options.pauseAfterEach {
                try runBlocking { [finishSegment, confirm] in
                    try await finishSegment(segment)
                    try await confirm(segment)
                }
            } else {
                // Finish segments one after another while the stream carries on.
                lock.withLock {
                    let task = Task { [background, finishSegment] in
                        try await background?.value
                        try await finishSegment(segment)
                    }
                    background = task
                    backgroundTasks.append(task)
                    if isCancelled { task.cancel() }
                }
            }
        }
        number += 1
        let folder = naming.folder(number)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent(naming.fileName(number))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        written = 0
        hasher = SHA256()
        onSegmentStarted(number)
    }

    private func closeSegment() throws -> CompletedSegment {
        guard let handle else { preconditionFailure("no open segment") }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        let folder = naming.folder(number)
        let segment = CompletedSegment(number: number, folder: folder,
                                       file: folder.appendingPathComponent(naming.fileName(number)),
                                       bytes: written, sha256: hasher.finalize().hexString)
        try ArchiveLayout.checksumLine(hexDigest: segment.sha256, fileName: segment.file.lastPathComponent)
            .write(to: folder.appendingPathComponent("\(segment.file.lastPathComponent).sha256"),
                   atomically: true, encoding: .utf8)
        lock.withLock { completed.append(segment) }
        return segment
    }

    /// Runs async work from the relay's dedicated thread and waits for it. Blocking is
    /// fine here: the relay thread isn't part of Swift's cooperative pool, and while
    /// it waits the helper processes simply stall on their full pipes.
    private func runBlocking(_ operation: @escaping @Sendable () async throws -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        let outcome = LockedBox<Result<Void, Error>>(.success(()))
        let task = Task {
            do { try await operation() } catch { outcome.value = .failure(error) }
            done.signal()
        }
        lock.withLock {
            bridged = task
            if isCancelled { task.cancel() }
        }
        done.wait()
        lock.withLock { bridged = nil }
        try outcome.value.get()
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
