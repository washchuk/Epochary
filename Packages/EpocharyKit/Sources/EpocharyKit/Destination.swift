import Foundation

/// Facts about the volume an archive is written to.
public struct DestinationVolume: Sendable, Equatable {
    public let fileSystemType: String
    public let mountedFrom: String
    public let formatDescription: String?
    /// Free space, or nil when the volume doesn't report it (some SMB servers don't).
    public let availableCapacity: Int64?

    public init(fileSystemType: String, mountedFrom: String, formatDescription: String?, availableCapacity: Int64?) {
        self.fileSystemType = fileSystemType
        self.mountedFrom = mountedFrom
        self.formatDescription = formatDescription
        self.availableCapacity = availableCapacity
    }

    /// Reads the volume holding `directory`, or nil if it can't be examined.
    public init?(containing directory: URL) {
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { return nil }
        func string<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let values = try? directory.resourceValues(forKeys: [
            .volumeLocalizedFormatDescriptionKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        // "Important usage" counts purgeable space on local disks; network volumes
        // often leave it empty or zero, so fall back to the plain figure.
        let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        self.init(fileSystemType: string(info.f_fstypename), mountedFrom: string(info.f_mntfromname),
                  formatDescription: values?.volumeLocalizedFormatDescription,
                  availableCapacity: important ?? values?.volumeAvailableCapacity.map(Int64.init))
    }

    /// LTFS tapes on macOS usually mount through macFUSE, so the file system type alone
    /// may just say "macfuse"; the mount source or format description names LTFS.
    public var isTape: Bool {
        [fileSystemType, mountedFrom, formatDescription ?? ""].contains { $0.lowercased().contains("ltfs") }
    }
}

/// How much space an archive needs at its destination.
public struct SpaceRequirement: Sendable, Equatable {
    public let bytes: Int64
    /// True when only one segment is staged at a time, so the figure is exact rather
    /// than an upper bound that assumes nothing compresses.
    public let isExact: Bool

    public init(for request: ArchiveRequest, stats: SourceStats) {
        func withParity(_ bytes: Int64) -> Int64 {
            guard let percent = request.parityPercent else { return bytes }
            return bytes + bytes * Int64(percent) / 100 + (2 << 20)
        }
        let readmeAndChecksums: Int64 = 1 << 20
        if let segmentation = request.segmentation, segmentation.pauseAfterEach {
            bytes = withParity(segmentation.size) + readmeAndChecksums
            isExact = true
        } else {
            let archive = SegmentOptions.maximumArchiveSize(for: stats)
            let segments = request.segmentation.map { Int64(SegmentOptions.estimatedCount(size: $0.size, stats: stats)) } ?? 1
            // par2's fixed overhead and a README come with every segment.
            bytes = withParity(archive) + segments * ((2 << 20) + readmeAndChecksums)
            isExact = false
        }
    }
}
