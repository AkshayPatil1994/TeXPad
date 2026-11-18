#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
# Downloads the prebuilt TeX bundle (./texlive and ./fonts) so you don't need a local TeX Live.
# The archive's SHA-256 is pinned in tools/bundle.conf and checked before anything is unpacked.
# usage: tools/fetch_bundle.sh [url-or-local-file]   (override only for testing / mirrors; the hash is still enforced)
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/bundle.conf
SRC="${1:-$BUNDLE_URL}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ARC="$TMP/bundle.tar.gz"
case "$SRC" in
  https://*|file://*) curl --fail --location --proto '=https,file' --proto-redir '=https' --output "$ARC" "$SRC" ;;
  *) cp "$SRC" "$ARC" ;;
esac
GOT="$(shasum -a 256 "$ARC" | cut -d' ' -f1)"
[ "$GOT" = "$BUNDLE_SHA256" ] || { echo "SHA-256 mismatch: expected $BUNDLE_SHA256, got $GOT — refusing to unpack" >&2; exit 1; }
# only accept the two expected top-level folders, no absolute or parent paths
if tar -tzf "$ARC" | grep -vE '^(texlive|fonts)(/|$)' | grep -q . || tar -tzf "$ARC" | grep -qE '(^/|\.\./)'; then
  echo "unexpected paths in archive — refusing to unpack" >&2; exit 1
fi
rm -rf texlive fonts
tar -xzf "$ARC"
echo "installed texlive/ ($(ls texlive | wc -l | tr -d ' ') files) and fonts/ ($(ls fonts | wc -l | tr -d ' ') files)"
