#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
# Packs the seeded ./texlive and ./fonts folders into one release asset (for maintainers).
# usage: tools/make_bundle.sh [output-dir]   -> <dir>/texpad-bundle-<version>.tar.gz and a .sha256 file
# Upload the tarball to a GitHub Release, then put its URL and hash in tools/bundle.conf.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/bundle.conf
OUT="${1:-.}"; mkdir -p "$OUT"
[ -d texlive ] && [ -d fonts ] || { echo "texlive/ and fonts/ not found: seed them first (see README)" >&2; exit 1; }
FILE="$OUT/texpad-bundle-$BUNDLE_VERSION.tar.gz"
# --no-xattrs/--no-mac-metadata keep AppleDouble ._ files out; sorted + owner-less for a stable archive
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$FILE" texlive fonts
( cd "$OUT" && shasum -a 256 "$(basename "$FILE")" > "$(basename "$FILE").sha256" )
ls -lh "$FILE"; cat "$FILE.sha256"
