import Foundation

/// The plain-text README written next to every archive: what each file is, which
/// tools made it, and the exact commands to restore it without Epochary.
struct ArchiveReadme: Sendable {
    let layout: ArchiveLayout
    let request: ArchiveRequest
    let stats: SourceStats
    let toolVersions: [Tool: String]
    let appVersion: String
    let created: Date

    /// What's only known once the whole archive is written.
    struct Outcome {
        let tarBytes: Int64
        let encryptedBytes: Int64
        let compressedSHA256: String
        let encryptedSHA256: String
        let segments: [CompletedSegment]
        let naming: SegmentNaming?
        let changes: [SourceChange]
    }

    private var encrypted: String { layout.encryptedFileName }
    private var compressed: String { layout.compressedFileName }
    private var decompress: String { request.longWindow ? "zstd -d --long=31" : "zstd -d" }
    private var hasParity: Bool { request.parityPercent != nil }

    // MARK: Final README

    func render(_ outcome: Outcome) -> String {
        if let naming = outcome.naming, !outcome.segments.isEmpty {
            return renderSegmented(outcome, naming: naming)
        }
        var files = [
            (encrypted, "The archive: a POSIX (pax) tar file, compressed with\nZstandard, encrypted with age."),
            ("\(encrypted).sha256", "SHA-256 checksum of the encrypted archive."),
            ("\(compressed).sha256", "SHA-256 checksum of the decrypted (still compressed) stream.\n"
                + "No file by this name exists; see step 2 below."),
        ]
        if let percent = request.parityPercent {
            files.append((layout.parityFileName, "PAR2 recovery data (\(percent)% redundancy) for repairing\n"
                + "damage to the archive, with its .vol*.par2 volumes."))
        }
        if !outcome.changes.isEmpty {
            files.append((layout.changesFileName, "Encrypted list of files that changed while archiving;\n"
                + "see CONSISTENCY below."))
        }
        files.append((layout.readme.lastPathComponent, "This file."))

        var check = """
          1. Check that the encrypted archive is intact:

               sha256sum -c \(encrypted).sha256

             (on macOS without GNU coreutils: shasum -a 256 -c \(encrypted).sha256)
        """
        if hasParity {
            check += """


                 If the check fails, repair the archive from the recovery data, then check again:

                   par2 repair \(layout.parityFileName)
            """
        }
        let steps = [check, """
          2. Optionally, check that decryption gives back exactly what was encrypted.
             Compare the printed hash with the one in \(compressed).sha256:

               age -d -i key.txt \(encrypted) | sha256sum
        """, """
          3. Decrypt, decompress and extract in one go:

               mkdir restored
               age -d -i key.txt \(encrypted) | \(decompress) | tar -xf - -C restored

        \(extractionNotes)
        """]

        return """
        EPOCHARY ARCHIVE: \(layout.name)
        \(createdLine)

        This folder holds an encrypted, compressed archive made only with open-source
        tools and open formats. Restoring it does not need Epochary or a Mac.


        FILES

        \(table(files))


        \(contents(outcome))


        \(consistency(outcome))


        \(recipientsSection)


        \(toolsSection)


        CHECKSUMS (SHA-256)

          \(outcome.encryptedSHA256)  \(encrypted)
          \(outcome.compressedSHA256)  \(compressed)


        HOW TO RESTORE

        \(steps.joined(separator: "\n\n"))

        """
    }

    private func renderSegmented(_ outcome: Outcome, naming: SegmentNaming) -> String {
        let count = outcome.segments.count
        let first = naming.folder(1).lastPathComponent
        let last = naming.folder(count).lastPathComponent
        let segmentLines = outcome.segments.map { segment in
            "  \(segment.file.lastPathComponent)  \(Self.count(Int(segment.bytes))) bytes\n"
                + "      sha256 \(segment.sha256)"
        }.joined(separator: "\n")
        let folderNames = count == 1 ? first : "\(first) … \(last)"

        var perSegment = [
            ("\(encrypted).NNN", "The segment: one piece of the encrypted archive."),
            ("\(encrypted).NNN.sha256", "SHA-256 checksum of the segment."),
        ]
        if let percent = request.parityPercent {
            perSegment.append(("\(encrypted).NNN.par2", "PAR2 recovery data (\(percent)% redundancy) for\n"
                + "the segment, with its .vol*.par2 volumes."))
        }
        perSegment.append((layout.readme.lastPathComponent, "A README for that segment. The last segment's README\n"
            + "is this file."))

        let medium = "/Volumes/MEDIUM"
        var check = """
          1. Check each segment where it is stored, inside its folder:

               sha256sum -c \(encrypted).NNN.sha256

             (on macOS without GNU coreutils: shasum -a 256 -c …)
        """
        if hasParity {
            check += """


                 If a check fails, repair that segment from its recovery data, then check again:

                   par2 repair \(encrypted).NNN.par2
            """
        }
        let steps = [check, """
          2. Copy every segment file into one folder, then join, decrypt, decompress and
             extract in one go. The segments must be joined in order; the file names sort
             correctly:

               mkdir restored
               cat \(naming.glob) | age -d -i key.txt | \(decompress) | tar -xf - -C restored

             To check the joined archive first, compare the output of
             "cat \(naming.glob) | sha256sum" with \(encrypted).sha256.
        """, """
          3. Without room to copy every segment first, stream them straight from their
             media, changing media when asked. Set MEDIUM to where each medium mounts:

               MEDIUM=\(medium)
               mkdir restored
               for n in $(seq -f '%0\(naming.width)g' 1 \(count)); do
                 printf 'Insert the medium holding segment %s, then press Return. ' "$n" >&2
                 read _ < /dev/tty
                 cat "$MEDIUM/\(layout.name)-segment-$n/\(encrypted).$n"
               done | age -d -i key.txt | \(decompress) | tar -xf - -C restored

        \(extractionNotes)
        """]

        return """
        EPOCHARY ARCHIVE: \(layout.name)
        \(createdLine)

        This archive is encrypted and compressed with open-source tools and open
        formats, then split into \(count) segment\(count == 1 ? "" : "s") so it fits on separate media. Restoring
        it does not need Epochary or a Mac, but it does need every segment, joined in
        order: a segment that's lost and can't be repaired makes the rest unreadable.


        LAYOUT

          Each segment is in its own folder, meant to be stored on one medium:
          \(folderNames). Each folder holds:

        \(table(perSegment))

          These files sit next to the segment folders, and are also in the last one:

        \(table([
            (layout.readme.lastPathComponent, "This file."),
            ("\(encrypted).sha256", "SHA-256 checksum of the whole encrypted archive, all\n"
                + "segments joined. No file by this name exists; see step 2."),
            ("\(compressed).sha256", "SHA-256 checksum of the decrypted (still compressed) stream."),
        ] + (outcome.changes.isEmpty ? [] : [
            (layout.changesFileName, "Encrypted list of files that changed while archiving;\n"
                + "see CONSISTENCY below."),
        ])))


        SEGMENTS

          Segments are \(Self.size(request.segmentation?.size ?? 0)) each, except the last.

        \(segmentLines)


        \(contents(outcome))


        \(consistency(outcome))


        \(recipientsSection)


        \(toolsSection)


        CHECKSUMS (SHA-256)

          \(outcome.encryptedSHA256)  \(encrypted)  (all segments joined)
          \(outcome.compressedSHA256)  \(compressed)


        HOW TO RESTORE

        \(steps.joined(separator: "\n\n"))

        """
    }

    // MARK: Per-segment README

    /// Written as each segment is finished, before later segments exist.
    func renderSegment(_ segment: CompletedSegment, naming: SegmentNaming) -> String {
        let name = segment.file.lastPathComponent
        var files = [
            (name, "Segment \(segment.number) of the encrypted archive."),
            ("\(name).sha256", "SHA-256 checksum of this segment."),
        ]
        if let percent = request.parityPercent {
            files.append(("\(name).par2", "PAR2 recovery data (\(percent)% redundancy) for this\n"
                + "segment, with its .vol*.par2 volumes."))
        }
        files.append((layout.readme.lastPathComponent, "This file."))

        var check = """
          sha256sum -c \(name).sha256

          (on macOS without GNU coreutils: shasum -a 256 -c \(name).sha256)
        """
        if hasParity {
            check += """


              If the check fails, repair the segment from its recovery data, then check again:

                par2 repair \(name).par2
            """
        }

        return """
        EPOCHARY ARCHIVE: \(layout.name), SEGMENT \(segment.number)
        \(createdLine)

        This folder holds segment \(segment.number) of an archive that is encrypted and compressed
        with open-source tools and open formats, then split into segments of
        \(Self.size(request.segmentation?.size ?? 0)) so it fits on separate media.

        Restoring needs every segment, joined in order. The README in the last
        segment's folder lists every segment with its checksum and gives the exact
        restore commands. In short, with all segment files in one folder:

          cat \(naming.glob) | age -d -i key.txt | \(decompress) | tar -xf - -C restored


        FILES

        \(table(files))

          This segment is \(Self.size(segment.bytes)), SHA-256
          \(segment.sha256)


        CHECK THIS SEGMENT

        \(check)


        \(recipientsSection)


        \(toolsSection)

        """
    }

    // MARK: Shared sections

    private var createdLine: String {
        "Created \(ISO8601DateFormatter().string(from: created)) by Epochary \(appVersion)"
    }

    private func contents(_ outcome: Outcome) -> String {
        """
        CONTENTS

          \(Self.count(stats.files)) files in \(request.sources.count) top-level item\(request.sources.count == 1 ? "" : "s"), \(Self.size(stats.bytes)) before compression.
          Tar stream: \(Self.size(outcome.tarBytes)). Encrypted archive: \(Self.size(outcome.encryptedBytes)).
          File names are stored only inside the encrypted archive.
        """
    }

    private func consistency(_ outcome: Outcome) -> String {
        guard !outcome.changes.isEmpty else {
            return """
            CONSISTENCY

              GNU tar reported no files changing or disappearing while it read them. It
              checks each file as it reads it, so the archive holds every file as it was at
              the moment it was read; it is not a snapshot of one instant.
            """
        }
        let count = outcome.changes.count
        return """
        CONSISTENCY

          \(Self.count(count)) file\(count == 1 ? "" : "s") or folder\(count == 1 ? "" : "s") changed or disappeared while this archive was being
          made, so it is not a consistent copy: a file that changed may mix old and new
          contents, and a file that was removed is missing. File names are only stored
          encrypted, so the list is in \(layout.changesFileName). To read it:

            age -d -i key.txt \(layout.changesFileName)
        """
    }

    private var recipientsSection: String {
        let lines = request.recipients
            .map { "  \($0.label.isEmpty ? "(unlabeled)" : $0.label)\n      \($0.publicKey)" }
            .joined(separator: "\n")
        return """
        ENCRYPTED TO

          Decrypting needs the private key (identity) for one of these public keys:

        \(lines)
        """
    }

    private var toolsSection: String {
        let tools: [(Tool, String)] = [
            (.tar, ""),
            (.zstd, "  (format: RFC 8878)"),
            (.age, "  (format: https://age-encryption.org/v1)"),
        ] + (hasParity ? [(.par2, "")] : [])
        let toolLines = tools.map { tool, note in
            "  \(tool.displayName) \(Self.versionNumber(toolVersions[tool]) ?? "")\n"
                + "      \(tool.homepage(forVersion: toolVersions[tool]))\(note)"
        }.joined(separator: "\n")
        let zstdSettings = "level \(request.compressionLevel)"
            + (request.longWindow ? ", long-distance window 2^31\n        (decompressing needs --long=31 and about 2 GiB of memory)" : "")
        return """
        TOOLS USED

        \(toolLines)

          Other implementations of the same formats work too, such as bsdtar, rage or
          par2cmdline.

          tar:  pax format, entries sorted by name, numeric owner IDs\(request.excludeFinderMetadata ? ", .DS_Store files skipped" : "")
          zstd: \(zstdSettings)
        """
    }

    private var extractionNotes: String {
        """
             key.txt is your age identity (private key) file. Any tar that reads POSIX
             pax archives works, including GNU tar and bsdtar. File owners are stored as
             numeric IDs and are only restored when extracting as root.
        """
    }

    /// Two columns: name, then a description whose extra lines line up under the first.
    private func table(_ rows: [(String, String)]) -> String {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { name, description in
            let indent = String(repeating: " ", count: width + 4)
            let lines = description.split(separator: "\n", omittingEmptySubsequences: false)
            return "  " + name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + lines[0]
                + lines.dropFirst().map { "\n" + indent + $0 }.joined()
        }.joined(separator: "\n")
    }

    /// "1.5.7" out of "*** Zstandard CLI (64-bit) v1.5.7, by Yann Collet ***".
    static func versionNumber(_ line: String?) -> String? {
        guard let line, let match = line.firstMatch(of: /\d+(?:\.\d+)+/) else { return line }
        return String(match.0)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(count(Int(bytes))) bytes (\(formatter.string(fromByteCount: bytes)))"
    }
}
