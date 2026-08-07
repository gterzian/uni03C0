#!/bin/bash
# Build and launch the app. Usage: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
xcodebuild -project Client.xcodeproj -scheme Client -configuration Debug build | tail -1

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/Client-"*/Build/Products/Debug -maxdepth 1 -name "Client.app" | head -1)
if [ -z "$APP" ]; then
    echo "App not found in DerivedData" >&2
    exit 1
fi
echo "Launching $APP"
open "$APP"
