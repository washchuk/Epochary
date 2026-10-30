# Epochary

A small Mac app for archiving files and folders for the long term, using only open
formats and open-source tools that will still be around in 20 years. Drag in files
and folders, choose who can decrypt them, and Epochary produces an encrypted,
compressed, checksummed archive (optionally with PAR2 recovery data) plus a plain-text
README explaining how to restore it **without Epochary or a Mac**.

## What it makes

For an archive named `archive-2025`, Epochary creates a folder `archive-2025/` containing:

| File | What it is |
|---|---|
| `archive-2025.tar.zst.age` | The archive: POSIX pax tar → Zstandard → age encryption |
| `archive-2025.tar.zst.age.sha256` | SHA-256 of the encrypted archive |
| `archive-2025.tar.zst.sha256` | SHA-256 of the decrypted (still compressed) stream |
| `archive-2025.tar.zst.age.par2`, `*.vol*.par2` | PAR2 recovery data, if chosen (3, 5 or 10%) |
| `archive-2025.README.txt` | Tool versions, recipients, checksums and exact restore commands |

The pipeline is streamed, so no unencrypted tar or zst file is ever written to disk:

```
gtar ──▶ zstd -19 --long=31 ──▶ age -r … ──▶ archive.tar.zst.age
                  │                │
                  │                └─ SHA-256 computed in-app as bytes pass
                  └─ zstd -d | gtar --list   (verifies the stream before anything is kept)
```

Checksum files use the GNU coreutils format, so `sha256sum -c` or `shasum -a 256 -c`
verifies them anywhere. If any step fails or you cancel, the partial output folder is removed.

### Segments (for tapes and other fixed-size media)

Turn on **Split into segments** to cut the encrypted archive into equal-size pieces, one
per medium (LTO-5 to LTO-9 tapes, Blu-ray discs, or a custom capacity). You pick the medium,
and Epochary sizes each segment to leave room on it for that segment's PAR2 data, its README
and 3% free space for the file system.

Each segment gets its own folder, which is everything that goes on one medium:

```
archive-2025/
├── archive-2025-segment-001/
│   ├── archive-2025.tar.zst.age.001
│   ├── archive-2025.tar.zst.age.001.sha256
│   ├── archive-2025.tar.zst.age.001.par2 (+ .vol*.par2)
│   └── archive-2025.README.txt          ← this segment's README
├── archive-2025-segment-002/ …
├── archive-2025-segment-003/ …           ← the last segment also holds the final README
├── archive-2025.README.txt               ← final README: every segment, its hash, restore steps
├── archive-2025.tar.zst.age.sha256       ← whole archive, all segments joined
└── archive-2025.tar.zst.sha256
```

Segments are staged on disk in one of two ways:

- **All at once:** every segment is written before you copy any, so the destination needs
  room for the whole archive.
- **One at a time:** Epochary pauses after each segment (once its checksum and PAR2 data
  are done) so you can copy its folder to the medium, and optionally delete it from disk,
  before the next one is written. Only one segment needs disk space at a time.

Segments are a plain byte split of one stream. Restoring needs every segment, joined in
order. A lost segment that PAR2 can't repair makes everything after it unreadable.

Segments are always staged on a disk, external drive (DAS) or network share, never written
straight to tape. Epochary refuses an LTFS volume as the save location when splitting:
each archive's encrypted stream is unique and can't be resumed, so a tape failure partway
through would ruin every segment written before it. Staged first, a segment that fails to
copy can simply be copied again to another tape.

## Restoring (no Epochary needed)

```bash
cd archive-2025
sha256sum -c archive-2025.tar.zst.age.sha256          # or: shasum -a 256 -c …
par2 repair archive-2025.tar.zst.age.par2             # only if the check fails
mkdir restored
age -d -i key.txt archive-2025.tar.zst.age | zstd -d --long=31 | tar -xf - -C restored
```

The `.tar.zst.sha256` file has no matching file on disk, since the compressed stream
only ever existed in memory. To check it, pipe `age -d … | sha256sum` and compare.

For a segmented archive, check and repair each segment in its own folder, then join the
segments with `cat` (their names sort in order):

```bash
cat archive-2025.tar.zst.age.[0-9][0-9][0-9] | age -d -i key.txt | zstd -d --long=31 | tar -xf - -C restored
```

The final README also gives a loop that streams segments straight from their media, asking
you to change media between them, for when there isn't room to copy them all to disk first.

## Requirements

- macOS 14 or later
- The command-line tools, from Homebrew:

  ```bash
  brew install gnu-tar zstd age par2
  ```

  Epochary looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and
  `/usr/bin`. You can point it at other copies in **Settings › Tools**. `par2` is only
  needed for recovery data.

## Keys

Archives are encrypted to one or more age **public keys**. In **Settings › Keys** you can
paste a public key (`age1…`, or an `ssh-ed25519`/`ssh-rsa` key), import one from an
existing identity file, or generate a new key pair with `age-keygen`, optionally
post-quantum. Epochary only ever stores public keys. Encrypt to at least two keys kept in
different places: without a private key, an archive can never be opened.

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Epochary.xcodeproj
```

The archive engine lives in the `EpocharyKit` Swift package, which has its own tests.
With the tools above installed, they run end to end: they create archives, restore them
with plain shell commands, and repair a deliberately damaged archive with par2.

```bash
cd Packages/EpocharyKit && swift test
```

## Notes and limitations

- **Metadata:** GNU tar on macOS has no extended-attribute support, so Finder tags,
  extended attributes, ACLs and resource forks aren't archived. File contents, names,
  permissions, modification times and symlinks are. `.DS_Store` files are skipped by
  default.
- **Memory:** `--long=31` uses a 2 GiB window. Decompressing needs `zstd -d --long=31`
  and about 2 GiB of RAM, and compressing large archives needs more. It can be turned off
  in **Settings › Archive**.
- **Protected folders:** the app isn't sandboxed, so macOS may ask for permission to read
  Documents, Desktop or other protected locations. Grant Full Disk Access to archive
  anything macOS protects.
- **Unreadable files:** if any file can't be read, the archive fails rather than silently
  leaving the file out.
- **Files that change while archiving:** GNU tar checks each file as it reads it. With
  **Stop if files change** on (it switches on when you turn on segments), the first file
  that changes or disappears stops the archive and nothing is kept. With it off, the archive
  is finished, the app lists what changed, and the README says the archive isn't a
  consistent copy. The list itself is saved encrypted, as `<name>.changes.txt.age`, since
  file names are never stored in plain text. There are no snapshots: making them needs an
  Apple-granted entitlement and only covers APFS, so for live data, archive from a snapshot
  you make yourself (a NAS snapshot folder works) or from a copy.
- **Sleep:** the Mac is kept from idle-sleeping while an archive is being made, including
  while it waits between segments, so helper processes and network shares stay connected.
  A share that disconnects anyway fails the archive, which then has to be started again.
- **Free space:** writing one segment at a time, Epochary won't start unless the destination
  has room for a segment and its recovery data. Otherwise it warns when the archive might not
  fit, since it can't know in advance how well the data will compress.
