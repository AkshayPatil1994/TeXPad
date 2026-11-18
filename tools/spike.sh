#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
# Build, install, run in the simulator; pull missing TeX files from local TeX Live; repeat manually.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEV="iPad Pro 11-inch (M5)"; BID=com.akshay.texpad
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project TexPad.xcodeproj -scheme TexPad -sdk iphonesimulator -destination "platform=iOS Simulator,name=$DEV" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD FAILED" 
xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl terminate "$DEV" $BID 2>/dev/null
xcrun simctl install "$DEV" build/Build/Products/Debug-iphonesimulator/TexPad.app
CONT=$(xcrun simctl get_app_container "$DEV" $BID data)
rm -f "$CONT/Library/Caches/texcache/tex-misses.txt"
( xcrun simctl launch --console-pty "$DEV" $BID 2>&1 & P=$!; sleep ${1:-60}; kill $P 2>/dev/null; xcrun simctl terminate "$DEV" $BID ) | grep -v "^$" | head -${2:-80}
if [ -f "$CONT/Library/Caches/texcache/tex-misses.txt" ]; then
  python3 tools/fetch_tex_files.py "$CONT/Library/Caches/texcache/tex-misses.txt"
fi
