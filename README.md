# Epochary

A small Mac app for archiving files and folders for the long term, using only open
formats and open-source tools that (hopefully) will still be around in 20 years. Drag in files
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

macOS 14 or later. Release builds of Epochary bundle their own copies of the tools, so
nothing else needs installing.

A build without bundled tools (see Building) uses copies installed on the Mac:

```bash
brew install gnu-tar zstd age par2
```

Epochary uses its bundled tools first, then looks in `/opt/homebrew/bin`, `/usr/local/bin`,
`/opt/local/bin` and `/usr/bin`. You can point it at other copies in **Settings › Tools**.
`par2` is only needed for recovery data.

## Bundled tools and their licenses

Epochary bundles unmodified builds of these tools in `Epochary.app/Contents/Helpers`:

| Tool | Version | License |
|---|---|---|
| [GNU tar](https://www.gnu.org/software/tar/) | 1.35 | GPL-3.0-or-later |
| [Zstandard](https://facebook.github.io/zstd/) | 1.5.7 | BSD-3-Clause (from its BSD/GPLv2 dual license), with libdivsufsort (MIT) |
| [age](https://age-encryption.org) (with age-keygen and age-plugin-batchpass) | 1.3.2 | BSD-3-Clause, plus the BSD-licensed Go standard library and modules it's built with |
| [par2cmdline-turbo](https://github.com/animetosho/par2cmdline-turbo) | 1.5.0 | GPL-2.0-or-later |

They're separate programs that Epochary runs as separate processes, so their licenses
don't extend to Epochary's own code. Their license texts and a notices file are bundled in
`Contents/Resources/Licenses` and shown in **Settings › Licenses**. Epochary's passphrase
generator also uses the BIP39 English word list from age's source, under age's license.

par2cmdline-turbo is a faster fork of par2cmdline (multi-threaded, with SIMD) that writes
the identical PAR2 format, which matters for tape-sized segments.

[`Vendor/build-tools.sh`](Vendor/build-tools.sh) builds the tools from upstream sources
pinned by SHA-256 (GNU tar's was also checked against its GPG signature). They're built as
universal binaries that depend only on macOS, with no Homebrew libraries. It needs Xcode's
command-line tools, Go and Rosetta:

```bash
Vendor/build-tools.sh
```

The output goes to `build/vendor/`. Xcode's "Bundle command-line tools" build phase copies
it into the app and signs each tool with the app's identity and the hardened runtime. A
Release build fails if the tools haven't been built. A Debug build without them falls back
to installed copies.

### Releasing

Releases are built by [`Scripts/release.sh`](Scripts/release.sh). From a clean, committed
tree, it:

- rebuilds the bundled tools
- builds the Release app, signed with the Developer ID and the hardened runtime
- checks every signature
- notarizes the app, then the DMG, and staples the approval to both
- checks the result with Gatekeeper
- gathers the release files in `build/release/<version>/assets`: the DMG, the tools'
  source archives and `build-tools.sh`, with a `SHA256SUMS` file for all of them

`Scripts/release.sh --dry-run` reuses the built tools and stops before notarization, to
check a build first.

Notarization needs Apple ID credentials, saved once in the keychain. The script uses the
profile name `epochary-notary` (or `NOTARY_PROFILE`):

```bash
xcrun notarytool store-credentials epochary-notary --apple-id <apple-id> --team-id 849VGKLAH8
```

Then tag the commit (`v<version>`), push the tag, and create the GitHub release with
everything in `assets`.

GNU tar and par2cmdline-turbo are GPL, and distributing their binaries requires making
their exact source available. Attaching the source archives to the same release as the app
does that. Keep them attached for as long as that release's app can be downloaded. The
bundled notices point to the releases page for the source.

## Keys or a passphrase

Archives are encrypted to one or more age **public keys**. In **Settings › Keys** you can
paste a public key (`age1…`, or an `ssh-ed25519`/`ssh-rsa` key), import one from an
existing identity file, or generate a new key pair with `age-keygen`, optionally
post-quantum. Epochary only ever stores public keys. Encrypt to at least two keys kept in
different places: without a private key, an archive can never be opened.

Or choose **Passphrase** under Encryption. The archive is an ordinary age
passphrase-encrypted file, and restoring is `age -d archive.tar.zst.age`, which asks for
the passphrase. A few things to know:

- age allows a passphrase only on its own, with no keys alongside it, so there's no backup:
  a forgotten passphrase means a lost archive.
- Anyone with a copy can keep guessing offline for as long as they like, so the passphrase
  has to be strong. **Generate Passphrase** makes one of ten random words (about 110 bits),
  the same kind `age -p` suggests.
- Epochary never saves the passphrase. It's held in memory only while the archive is made.
- age only reads passphrases typed at a terminal, so Epochary hands it over through age's
  official `age-plugin-batchpass` plugin. Only making the archive needs the plugin.

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Epochary.xcodeproj
```

The archive engine lives in the `EpocharyKit` Swift package, which has its own tests.
With the tools above installed, they run end to end: they create archives, restore them
with plain shell commands, and repair a deliberately damaged archive with par2. To test
against the bundled builds instead, point the tests at them:

```bash
cd Packages/EpocharyKit && swift test
EPOCHARY_TOOLS_DIR="$PWD/../../build/vendor/bin" swift test
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
  you make yourself (a NAS snapshot folder works) or from a copy. In other words, Epochary is designed for static datasets, not backups of live systems or those wanting differential or incremental backups.
- **Sleep:** the Mac is kept from idle-sleeping while an archive is being made, including
  while it waits between segments, so helper processes and network shares stay connected.
  A share that disconnects anyway fails the archive, which then has to be started again.
- **Free space:** writing one segment at a time, Epochary won't start unless the destination
  has room for a segment and its recovery data. Otherwise it warns when the archive might not
  fit, since it can't know in advance how well the data will compress.

## License

Copyright © 2026 Matt Washchuk.

Epochary is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License](LICENSE), version 3 or (at your option) any later version.
It is distributed in the hope that it will be useful, but without any warranty; see the
license for details.

The bundled command-line tools keep their own licenses (see
[Bundled tools and their licenses](#bundled-tools-and-their-licenses)), and
`PassphraseWords.swift` is under age's BSD 3-Clause license.
