#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
# Headless project build in the simulator: tools/autotest.sh <project dir> [main.tex] [seconds]
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEV="iPad Pro 11-inch (M5)"; BID=com.akshay.texpad
cd "$(dirname "$0")/.."
PROJ=$(cd "$1" && pwd); MAIN=${2:-main.tex}
xcodegen generate >/dev/null
xcodebuild -project TexPad.xcodeproj -scheme TexPad -sdk iphonesimulator -destination "platform=iOS Simulator,name=$DEV" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD FAILED"
xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl terminate "$DEV" $BID 2>/dev/null
xcrun simctl install "$DEV" build/Build/Products/Debug-iphonesimulator/TexPad.app
CONT=$(xcrun simctl get_app_container "$DEV" $BID data)
rm -f "$CONT/Library/Caches/texcache/tex-misses.txt" /tmp/ipadtex-autotest.pdf
export SIMCTL_CHILD_IPADTEX_VERBOSE="$VERBOSE" SIMCTL_CHILD_IPADTEX_AUTOTEST="$PROJ" SIMCTL_CHILD_IPADTEX_MAIN="$MAIN"
OUT=$(mktemp)
xcrun simctl launch --console-pty "$DEV" $BID > "$OUT" 2>&1 &
P=$!
for i in $(seq 1 ${3:-90}); do sleep 1; grep -q "\[autotest\] done" "$OUT" && break; done
kill $P 2>/dev/null; xcrun simctl terminate "$DEV" $BID 2>/dev/null
grep -E "autotest|\[tex\] miss" "$OUT" | grep -v "nul:"; sed -n '/autotest\] LOG/,$p' "$OUT" | head -${4:-0}
if [ -f "$CONT/Library/Caches/texcache/tex-misses.txt" ]; then python3 tools/fetch_tex_files.py "$CONT/Library/Caches/texcache/tex-misses.txt"; fi
