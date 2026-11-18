#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
# Build, install and launch TexPad in the simulator, optionally opening a sample and taking a screenshot.
# usage: tools/run-sim.sh [Sample] [wait-seconds] [screenshot.png]
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEV="iPad Pro 11-inch (M5)"; BID=com.akshay.texpad
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project TexPad.xcodeproj -scheme TexPad -sdk iphonesimulator -destination "platform=iOS Simulator,name=$DEV" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD FAILED"
xcrun simctl boot "$DEV" 2>/dev/null; open -a Simulator
xcrun simctl terminate "$DEV" $BID 2>/dev/null
xcrun simctl install "$DEV" build/Build/Products/Debug-iphonesimulator/TexPad.app
[ -n "$SHOW_PDF" ] && export SIMCTL_CHILD_TEXPAD_SHOW_PDF=1
[ -n "$EDITOR_JS" ] && export SIMCTL_CHILD_TEXPAD_EDITOR_JS="$EDITOR_JS"
export SIMCTL_CHILD_TEXPAD_RESET_SAMPLE=1
[ -n "$1" ] && export SIMCTL_CHILD_TEXPAD_OPEN_SAMPLE="$1" SIMCTL_CHILD_TEXPAD_BUILD=1
xcrun simctl launch "$DEV" $BID >/dev/null
sleep ${2:-20}
[ -n "$3" ] && xcrun simctl io "$DEV" screenshot "$3" >/dev/null 2>&1 && echo "screenshot: $3"
