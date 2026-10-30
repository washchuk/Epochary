import Foundation

/// Runs blocking work on a dedicated thread so pipe reads and writes never stall
/// Swift's cooperative thread pool.
func onDedicatedThread<T: Sendable>(_ name: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
        }
        thread.name = "Epochary.\(name)"
        thread.start()
    }
}

/// Writing to a pipe whose reader has exited must surface as an EPIPE error,
/// not a SIGPIPE that kills the app.
let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

/// Environment for child processes. GUI apps launch without a locale, and GNU tar
/// needs one to store non-ASCII file names as UTF-8 in pax headers.
func childEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "en_US.UTF-8"
    return environment
}

/// A child process whose stdin/stdout the caller wires up before `start()`.
/// Standard error is collected (last 64 KiB) for error messages.
final class RunningProcess: @unchecked Sendable {
    struct Termination: Sendable {
        let status: Int32
        /// False when the process was killed by a signal, e.g. by `terminate()`.
        let exitedNormally: Bool
    }

    let name: String
    let process = Process()
    private let stderrPipe = Pipe()
    private let stderrFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stderrTail = Data()
    private var terminatedByRequest = false
    private static let stderrLimit = 64 * 1024
    /// Called with each line of standard error as it arrives. Set before `start()`.
    var onStderrLine: (@Sendable (String) -> Void)?

    init(name: String, executable: URL, arguments: [String], workingDirectory: URL? = nil) {
        _ = ignoreSIGPIPE
        self.name = name
        process.executableURL = executable
        process.arguments = arguments
        process.environment = childEnvironment()
        process.standardError = stderrPipe
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
    }

    func start() throws {
        try process.run()
        let handle = stderrPipe.fileHandleForReading
        let onLine = onStderrLine
        Thread.detachNewThread { [self] in
            var pending = Data()
            while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                lock.withLock {
                    stderrTail.append(chunk)
                    if stderrTail.count > Self.stderrLimit {
                        stderrTail.removeFirst(stderrTail.count - Self.stderrLimit)
                    }
                }
                guard let onLine else { continue }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
            try? handle.close()
            stderrFinished.signal()
        }
    }

    /// Waits for the process to exit and for its standard error to be fully read.
    func waitForExit() async -> Termination {
        let result = try? await onDedicatedThread("wait.\(name)") { [self] in
            process.waitUntilExit()
            stderrFinished.wait()
            return Termination(status: process.terminationStatus,
                               exitedNormally: process.terminationReason == .exit)
        }
        return result ?? Termination(status: -1, exitedNormally: false)
    }

    /// Stops the process if it's still running, and remembers that its exit status is our doing.
    func terminate() {
        lock.withLock {
            guard process.isRunning else { return }
            terminatedByRequest = true
            process.terminate()
        }
    }

    var wasTerminatedByRequest: Bool { lock.withLock { terminatedByRequest } }

    var stderrText: String {
        lock.withLock { String(decoding: stderrTail, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdoutData: Data
        let stderr: String

        var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    }

    /// Runs a short-lived command to completion, capturing its output.
    static func capture(_ executable: URL, arguments: [String], stdin: Data = Data(),
                        workingDirectory: URL? = nil) async throws -> Output {
        let running = RunningProcess(name: executable.lastPathComponent, executable: executable, arguments: arguments,
                                     workingDirectory: workingDirectory)
        let input = Pipe()
        let output = Pipe()
        running.process.standardInput = input
        running.process.standardOutput = output
        try running.start()

        async let stdoutData = onDedicatedThread("capture.stdout") {
            try output.fileHandleForReading.readToEnd() ?? Data()
        }
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()

        let data = try await stdoutData
        let termination = await running.waitForExit()
        return Output(status: termination.status, stdoutData: data, stderr: running.stderrText)
    }
}
