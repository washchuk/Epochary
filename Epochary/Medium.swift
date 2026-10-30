import Foundation

/// Storage media an archive can be split across, by native (uncompressed) capacity.
/// Archives are already compressed and encrypted, so drive compression adds nothing.
enum Medium: String, CaseIterable, Identifiable {
    case lto5, lto6, lto7, lto8, lto9
    case bluRay25, bluRay50, bluRay100
    case custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lto5: "LTO-5 tape (1.5 TB)"
        case .lto6: "LTO-6 tape (2.5 TB)"
        case .lto7: "LTO-7 tape (6 TB)"
        case .lto8: "LTO-8 tape (12 TB)"
        case .lto9: "LTO-9 tape (18 TB)"
        case .bluRay25: "BD-R (25 GB)"
        case .bluRay50: "BD-R DL (50 GB)"
        case .bluRay100: "BD-R XL (100 GB)"
        case .custom: "Custom size"
        }
    }

    var capacity: Int64? {
        switch self {
        case .lto5: 1_500_000_000_000
        case .lto6: 2_500_000_000_000
        case .lto7: 6_000_000_000_000
        case .lto8: 12_000_000_000_000
        case .lto9: 18_000_000_000_000
        case .bluRay25: 25_025_314_816
        case .bluRay50: 50_050_629_632
        case .bluRay100: 100_103_356_416
        case .custom: nil
        }
    }
}

enum CapacityUnit: String, CaseIterable, Identifiable {
    case gigabytes = "GB", terabytes = "TB", gibibytes = "GiB", tebibytes = "TiB"

    var id: String { rawValue }

    var bytes: Double {
        switch self {
        case .gigabytes: 1e9
        case .terabytes: 1e12
        case .gibibytes: 1_073_741_824
        case .tebibytes: 1_099_511_627_776
        }
    }
}
