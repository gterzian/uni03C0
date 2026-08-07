#!/bin/bash
# Build and launch the PiMacApp app. Usage: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
xcodebuild -project PiNative.xcodeproj -scheme PiMacApp -configuration Debug build | tail -1

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/PiNative-"*/Build/Products/Debug -maxdepth 1 -name "PiMacApp.app" | head -1)
if [ -z "$APP" ]; then
    echo "App not found in DerivedData" >&2
    exit 1
fi
echo "Launching $APP"
open "$APP"
