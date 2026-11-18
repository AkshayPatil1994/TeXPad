#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
#
# Builds libgit2 from source as Vendor/libgit2.xcframework (iOS device + simulator, static).
#  - pinned release tag AND commit hash (the clone is rejected if they don't match)
#  - no TLS and no SSH inside libgit2: HTTPS goes through TexPad's URLSession transport (TexPad/Git/GitTransport.c),
#    so iOS does TLS 1.3 and certificate validation and no OpenSSL is shipped
# Requires: Xcode command line tools, cmake (brew install cmake). Takes a few minutes.
set -euo pipefail

TAG="v1.9.7"
COMMIT="49e408b3208bc3093757a1c2db938d3590f3f412"
MIN_IOS="17.0"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-libgit2"
SRC="$WORK/src"
OUT="$ROOT/Vendor/libgit2.xcframework"

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)"; exit 1; }
mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/libgit2/libgit2.git "$SRC"
fi
ACTUAL="$(git -C "$SRC" rev-parse HEAD)"
if [ "$ACTUAL" != "$COMMIT" ]; then
  echo "libgit2 $TAG resolved to $ACTUAL, expected $COMMIT — refusing to build" >&2
  exit 1
fi

build_slice() {  # name sysroot archs
  local name="$1" sysroot="$2" archs="$3" dir="$WORK/build-$1"
  cmake -S "$SRC" -B "$dir" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DBUILD_FUZZERS=OFF \
    -DUSE_SSH=OFF -DUSE_HTTPS=OFF -DUSE_AUTH_NTLM=OFF -DUSE_AUTH_NEGOTIATE=OFF -DUSE_GSSAPI=OFF \
    -DUSE_HTTP_PARSER=builtin -DREGEX_BACKEND=builtin -DUSE_BUNDLED_ZLIB=ON \
    -DUSE_SHA1=CollisionDetection -DUSE_SHA256=builtin -DUSE_NSEC=ON -DUSE_THREADS=ON >"$dir.log" 2>&1 || { tail -30 "$dir.log"; exit 1; }
  cmake --build "$dir" --parallel "$(sysctl -n hw.ncpu)" >>"$dir.log" 2>&1 || { tail -30 "$dir.log"; exit 1; }
  ls "$dir"/libgit2*.a >/dev/null
}

echo "building device slice…";    build_slice ios iphoneos "arm64"
echo "building simulator slice…"; build_slice sim iphonesimulator "arm64;x86_64"

# Headers (public API + the transport plug-in API) with a module map.
HDR="$WORK/headers"
rm -rf "$HDR" && mkdir -p "$HDR"
cp -R "$SRC/include/git2" "$HDR/git2"
cp "$SRC/include/git2.h" "$HDR/git2.h"
cat > "$HDR/Clibgit2.h" <<'EOF'
#include <git2.h>
#include <git2/sys/transport.h>
EOF
cat > "$HDR/module.modulemap" <<'EOF'
module Clibgit2 {
    header "Clibgit2.h"
    link "z"
    link "iconv"
    export *
}
EOF

rm -rf "$OUT"
mkdir -p "$ROOT/Vendor"
xcodebuild -create-xcframework \
  -library "$WORK/build-ios/libgit2.a" -headers "$HDR" \
  -library "$WORK/build-sim/libgit2.a" -headers "$HDR" \
  -output "$OUT"
echo "built $OUT ($TAG, $COMMIT)"
