#!/bin/bash
#
# Builds the command-line tools Epochary bundles, from pinned and checksummed upstream
# sources, as universal (Apple silicon + Intel) binaries that depend only on macOS.
#
#   Vendor/build-tools.sh [output-directory]     (default: build/vendor)
#
# Output:
#   bin/       gtar, zstd, age, age-keygen, age-plugin-batchpass, par2
#              (copied into Epochary.app/Contents/Helpers)
#   Licenses/  license texts and THIRD-PARTY-NOTICES.txt   (copied into the app's Resources)
#   sources/   the exact source archives and this script. Publish these with every release
#              that ships the binaries: GNU tar and par2cmdline-turbo are GPL, which requires
#              their corresponding source to be available from the same place.
#
# Needs Xcode's command-line tools, Go (for age) and Rosetta (for the Intel builds).

set -euo pipefail

TAR_VERSION=1.35
TAR_URL=https://ftp.gnu.org/gnu/tar/tar-$TAR_VERSION.tar.xz
TAR_SHA256=4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16   # GPG signature checked 2026-10-30

ZSTD_VERSION=1.5.7
ZSTD_URL=https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz
ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

AGE_VERSION=1.3.2
AGE_URL=https://github.com/FiloSottile/age/archive/refs/tags/v$AGE_VERSION.tar.gz
AGE_SHA256=b07c28c6c4bdafa272073a310b75bc22c49da8904585a89c30e5ca4233e63843

PAR2_VERSION=1.5.0
PAR2_URL=https://github.com/animetosho/par2cmdline-turbo/releases/download/v$PAR2_VERSION/par2cmdline-turbo-$PAR2_VERSION.tar.xz
PAR2_SHA256=035584144d3ac3b08fb5d7d4b844f60cf97404b6469f6aed7d9b9430a25bef0e

MACOS_MIN=14.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-$ROOT/build/vendor}" && cd "${1:-$ROOT/build/vendor}" && pwd)
DOWNLOADS=$OUT/downloads
WORK=$OUT/work
JOBS=$(sysctl -n hw.ncpu)

GO=$(command -v go) || { echo "error: Go is needed to build age (brew install go)" >&2; exit 1; }
arch -x86_64 /usr/bin/true 2>/dev/null || { echo "error: Rosetta is needed for the Intel builds" >&2; exit 1; }

# Build with only the system toolchain in reach, so nothing links against Homebrew.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CFLAGS CXXFLAGS LDFLAGS
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN

clean() { [ -d "$1" ] && chmod -R u+w "$1" && rm -rf "$1"; return 0; }  # Go's module cache is read-only
clean "$WORK"; clean "$OUT/bin"; clean "$OUT/Licenses"; clean "$OUT/sources"
mkdir -p "$DOWNLOADS" "$WORK" "$OUT/bin" "$OUT/Licenses" "$OUT/sources"

fetch() {  # url sha256 file-name → path of the verified download
    local file=$DOWNLOADS/$3
    if [ ! -f "$file" ]; then
        curl -fsSL -o "$file.part" "$1"
        mv "$file.part" "$file"
    fi
    echo "$2  $file" | shasum -a 256 -c --status || { echo "error: checksum mismatch for $file" >&2; exit 1; }
    echo "$file"
}

unpack() {  # archive arch → fresh source directory for that architecture
    local dir=$WORK/$2/$(basename "$1")
    mkdir -p "$dir"
    tar -xf "$1" -C "$dir"
    echo "$dir/$(ls "$dir")"
}

run_as() {  # arch command...  — Intel builds run under Rosetta so configure checks are native
    if [ "$1" = x86_64 ]; then shift; arch -x86_64 /bin/bash -c "$*"; else shift; /bin/bash -c "$*"; fi
}

universal() {  # name — joins the per-architecture builds
    lipo -create "$WORK/$1-arm64" "$WORK/$1-x86_64" -output "$OUT/bin/$1"
    chmod 755 "$OUT/bin/$1"
}

echo "==> Downloading and verifying sources"
TAR_SRC=$(fetch "$TAR_URL" "$TAR_SHA256" tar-$TAR_VERSION.tar.xz)
ZSTD_SRC=$(fetch "$ZSTD_URL" "$ZSTD_SHA256" zstd-$ZSTD_VERSION.tar.gz)
AGE_SRC=$(fetch "$AGE_URL" "$AGE_SHA256" age-$AGE_VERSION.tar.gz)
PAR2_SRC=$(fetch "$PAR2_URL" "$PAR2_SHA256" par2cmdline-turbo-$PAR2_VERSION.tar.xz)

for arch in arm64 x86_64; do
    cc="clang -arch $arch -mmacosx-version-min=$MACOS_MIN"

    echo "==> GNU tar $TAR_VERSION ($arch)"
    src=$(unpack "$TAR_SRC" "$arch")
    tar_src=$src
    # tar 1.35's Makefile leaves out the iconv library configure finds, so it goes in LIBS.
    # strchrnul is in the SDK but only exists from macOS 15.4, so tar uses gnulib's copy.
    run_as $arch "cd '$src' && ./configure --quiet --disable-nls --without-selinux --without-posix-acls \
        --without-xattrs CC='$cc' CFLAGS='-O2' LIBS='-liconv' ac_cv_func_strchrnul=no >/dev/null \
        && make -s -j$JOBS >/dev/null"
    cp "$src/src/tar" "$WORK/gtar-$arch"

    echo "==> zstd $ZSTD_VERSION ($arch)"
    src=$(unpack "$ZSTD_SRC" "$arch")
    zstd_src=$src
    # No zlib/xz/lz4 support (not needed, and would add libraries) and no legacy v0.x formats.
    run_as $arch "make -s -C '$src/programs' -j$JOBS zstd CC='$cc' CFLAGS='-O3' HAVE_ZLIB=0 HAVE_LZMA=0 \
        HAVE_LZ4=0 HAVE_THREAD=1 ZSTD_LEGACY_SUPPORT=0 >/dev/null"
    cp "$src/programs/zstd" "$WORK/zstd-$arch"

    echo "==> par2cmdline-turbo $PAR2_VERSION ($arch)"
    src=$(unpack "$PAR2_SRC" "$arch")
    par2_src=$src
    run_as $arch "cd '$src' && ./configure --quiet CC='$cc' CXX='clang++ -arch $arch -mmacosx-version-min=$MACOS_MIN' \
        CXXFLAGS='-O2' >/dev/null && make -s -j$JOBS par2 >/dev/null"
    cp "$src/par2" "$WORK/par2-$arch"
done

echo "==> age $AGE_VERSION"
src=$(unpack "$AGE_SRC" go)
export GOPATH=$WORK/gopath GOMODCACHE=$WORK/gopath/pkg/mod GOFLAGS=-mod=readonly CGO_ENABLED=0 GOTOOLCHAIN=local
for arch in arm64 x86_64; do
    goarch=$([ $arch = x86_64 ] && echo amd64 || echo arm64)
    # age-plugin-batchpass lets Epochary hand age a passphrase without a terminal.
    for cmd in age age-keygen age-plugin-batchpass; do
        (cd "$src" && GOOS=darwin GOARCH=$goarch "$GO" build -trimpath \
            -ldflags "-X main.Version=v$AGE_VERSION" -o "$WORK/$cmd-$arch" ./cmd/$cmd)
    done
done

for tool in gtar zstd par2 age age-keygen age-plugin-batchpass; do universal $tool; done

echo "==> Checking the binaries"
for tool in "$OUT"/bin/*; do
    archs=$(lipo -archs "$tool")
    [ "$archs" = "x86_64 arm64" ] || [ "$archs" = "arm64 x86_64" ] || { echo "error: $tool is $archs" >&2; exit 1; }
    # Library lines are indented; the others are per-architecture headers.
    if otool -L "$tool" | grep -E '^\s' | grep -vE '^\s+/(usr/lib|System/Library)/' | grep -q .; then
        echo "error: $tool links libraries outside macOS:" >&2; otool -L "$tool" >&2; exit 1
    fi
    # A weak import is a function newer than MACOS_MIN that configure found in the SDK;
    # on older macOS it's missing and the tool crashes when it calls it.
    if nm -m "$tool" | grep '(undefined) weak external' >&2; then
        echo "error: $tool uses functions that macOS $MACOS_MIN doesn't have (above)" >&2; exit 1
    fi
    "$tool" --version >/dev/null 2>&1 || "$tool" -V >/dev/null 2>&1 || { echo "error: $tool doesn't run" >&2; exit 1; }
    arch -x86_64 "$tool" --version >/dev/null 2>&1 || arch -x86_64 "$tool" -V >/dev/null 2>&1 \
        || { echo "error: $tool doesn't run as Intel" >&2; exit 1; }
done

echo "==> Collecting licenses"
L=$OUT/Licenses
first_comment() { awk 'NR==1,/\*\//' "$1"; }  # a file's leading /* … */ license header
cp "$tar_src/COPYING" "$L/gnu-tar.GPL-3.0.txt"
cp "$par2_src/COPYING" "$L/par2cmdline-turbo.GPL-2.0.txt"
cp "$zstd_src/LICENSE" "$L/zstd.BSD-3-Clause.txt"
first_comment "$zstd_src/lib/dictBuilder/divsufsort.c" > "$L/zstd-divsufsort.MIT.txt"
cp "$src/LICENSE" "$L/age.BSD-3-Clause.txt"
first_file() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
GOROOT_DIR=$("$GO" env GOROOT)  # Homebrew moves Go's LICENSE up out of GOROOT
go_license=$(first_file "$GOROOT_DIR/LICENSE" "$GOROOT_DIR/../LICENSE")
[ -n "$go_license" ] || { echo "error: can't find Go's LICENSE near $GOROOT_DIR" >&2; exit 1; }
cp "$go_license" "$L/go-standard-library.BSD-3-Clause.txt"
# Every Go module compiled into age, as recorded in the binary itself.
go_modules=$("$GO" version -m "$WORK/age-arm64" "$WORK/age-keygen-arm64" "$WORK/age-plugin-batchpass-arm64" | awk '$1 == "dep" { print $2 "@" $3 }' | sort -u)
for module in $go_modules; do
    license=$(first_file "$GOMODCACHE/$module"/LICENSE*)
    [ -n "$license" ] || { echo "error: no license file for Go module $module" >&2; exit 1; }
    cp "$license" "$L/go-$(echo "${module%@*}" | tr '/' '-').txt"
done
chmod 644 "$L"/*  # files from Go's module cache are read-only

cat > "$L/THIRD-PARTY-NOTICES.txt" <<EOF
Epochary includes the following open-source command-line tools, unmodified, in
Epochary.app/Contents/Helpers. Each is a separate program, run by Epochary as a
separate process, and each keeps its own license. The license texts are in this folder.

GNU tar $TAR_VERSION  (gtar)
  License: GNU General Public License, version 3 or later  (gnu-tar.GPL-3.0.txt)
  Copyright (C) Free Software Foundation, Inc.
  https://www.gnu.org/software/tar/

par2cmdline-turbo $PAR2_VERSION  (par2)
  License: GNU General Public License, version 2 or later  (par2cmdline-turbo.GPL-2.0.txt)
  Based on par2cmdline; includes ParPar's processing backend (public domain, CC0),
  CRC code from zlib-ng / Intel (zlib license) and Hedley (CC0).
  https://github.com/animetosho/par2cmdline-turbo

Zstandard $ZSTD_VERSION  (zstd)
  License: BSD 3-Clause, chosen from its BSD-or-GPLv2 dual license  (zstd.BSD-3-Clause.txt)
  Copyright (c) Meta Platforms, Inc. and affiliates.
  Includes libdivsufsort (MIT, zstd-divsufsort.MIT.txt).
  https://facebook.github.io/zstd/

age $AGE_VERSION  (age, age-keygen, age-plugin-batchpass)
  License: BSD 3-Clause  (age.BSD-3-Clause.txt)
  Copyright 2019 The age Authors
  Built with Go, whose standard library (go-standard-library.BSD-3-Clause.txt) and these
  modules are compiled in, each under the license in the matching go-*.txt file:
$(for module in $go_modules; do echo "    $module"; done)
  https://age-encryption.org
  Epochary's passphrase generator also uses the BIP39 English word list from age's
  source, under the same license.

SOURCE CODE

The exact source code these binaries were built from, and the script that built them
(build-tools.sh), are published alongside every Epochary release that includes them,
at https://github.com/washchuk/Epochary/releases. The build script is also in the
Epochary repository at Vendor/build-tools.sh.
EOF

echo "==> Gathering sources for release"
cp "$TAR_SRC" "$ZSTD_SRC" "$AGE_SRC" "$PAR2_SRC" "$OUT/sources/"
cp "$0" "$OUT/sources/build-tools.sh"
(cd "$OUT/sources" && shasum -a 256 * > SHA256SUMS)

clean "$WORK"
echo "==> Done: $OUT"
ls -l "$OUT/bin"
