#!/bin/bash
# Build and launch the app. Usage: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
xcodebuild -project Client.xcodeproj -scheme Client -configuration Debug build | tail -1

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/Client-"*/Build/Products/Debug -maxdepth 1 -name "uni03C0.app" | head -1)
if [ -z "$APP" ]; then
    echo "App not found in DerivedData" >&2
    exit 1
fi

# Quit any running instance FIRST — `open` on an already-running app just
# activates the OLD binary, which looks like "nothing was fixed".
osascript -e 'quit app id "com.gterzian.client"' >/dev/null 2>&1 || true
sleep 0.5
echo "Launching $APP"
open "$APP"
