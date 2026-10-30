import Foundation

/// A file or folder that GNU tar saw change while archiving it.
public struct SourceChange: Sendable, Hashable {
    public enum Kind: String, Sendable {
        /// Modified while being read; the archived copy may mix old and new contents.
        case changed
        /// Deleted after tar listed its folder but before reading it; it's missing.
        case removed
        /// Got shorter while being read; tar padded the archived copy with zeros.
        case shrank
    }

    /// The path as stored in the archive, relative to its top-level item.
    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    public var summary: String {
        switch kind {
        case .changed: "changed while being read"
        case .removed: "removed before it was read"
        case .shrank: "shrank while being read"
        }
    }

    /// Parses a line of GNU tar's standard error, such as
    /// "gtar: Photos/a.jpg: file changed as we read it". Nil for other messages.
    static func parse(tarMessage line: String) -> SourceChange? {
        let lowered = line.lowercased()
        let kind: Kind
        if lowered.hasSuffix("file changed as we read it") {
            kind = .changed
        } else if lowered.hasSuffix("file removed before we read it") {
            kind = .removed
        } else if lowered.contains(": file shrank by ") {
            kind = .shrank
        } else {
            return nil
        }
        // "<program>: <path>: <message>", where the path itself may contain ": ".
        guard let program = line.range(of: ": "),
              let message = line.range(of: ": ", options: .backwards),
              program.upperBound <= message.lowerBound else { return nil }
        return SourceChange(path: String(line[program.upperBound..<message.lowerBound]), kind: kind)
    }
}

/// Sorts tar's warnings into source changes and everything else, as they arrive.
final class ChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var changeList: [SourceChange] = []
    private var otherLines: [String] = []
    private var stopped = false

    /// Records a line and returns the change it reports, if any.
    func record(_ line: String) -> SourceChange? {
        let change = SourceChange.parse(tarMessage: line)
        lock.withLock {
            if let change {
                // Bounded, in case a whole tree is being rewritten underneath us.
                if changeList.count < 100_000 { changeList.append(change) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, otherLines.count < 1000 {
                otherLines.append(line)
            }
        }
        return change
    }

    func markStopped() { lock.withLock { stopped = true } }

    var changes: [SourceChange] { lock.withLock { changeList } }
    var warnings: [String] { lock.withLock { otherLines } }
    var didStop: Bool { lock.withLock { stopped } }
}
