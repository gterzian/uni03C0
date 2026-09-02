#!/bin/bash
# Builds and runs the CoordinatorTests — the transcript Coordinator +
# renderer sources against the REAL Core framework — using plain swiftc + a
# stub XCTest module. This is the only route that works inside the app's
# Seatbelt sandbox: xcodebuild's "Resolve Package Graph" step runs SPM's
# manifest sandbox (`sandbox-exec`), which the Seatbelt policy denies.
#
# Prerequisite: `swift test --disable-sandbox` has built the harness Core
# module at least once (`.build/arm64-apple-macosx/debug`), so the REAL Core
# (TranscriptStore, HeightCache, StreamingRefreshGate, …) is available to
# link against. The renderer's FontSettings is stubbed because the
# @Observable macro's plugin server is blocked in the sandbox.
#
# From a terminal, `xcodebuild -scheme CoordinatorTests test` runs the same
# test files with the real XCTest and the real FontSettings.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=.build/arm64-apple-macosx/debug
OUT=/tmp/coordtests
mkdir -p "$OUT/mod"

# 1. The stub XCTest module, compiled under the SAME default isolation
#    (MainActor) as the test sources, so the isolation checks pass by
#    construction (see AGENTS.md → RenderingTests).
swiftc -emit-library -module-name XCTest -swift-version 6 \
  -default-isolation MainActor -target arm64-apple-macosx26.0 \
  -emit-module -emit-module-path "$OUT/mod" \
  CoordinatorTests/Harness/XCTestStub.swift -o "$OUT/libXCTest.dylib"

# 2. Compile the coordinator + renderer + view-model stand-in + tests into one
#    binary, linking the real Core module built by the SwiftPM harness (its
#    dependencies — Subprocess, SystemPackage, the C shims — come from the
#    same build).
CORE_MODS="$BUILD/Modules"
SUB_MODS="$(dirname "$(find "$BUILD" -name Subprocess.swiftmodule | head -1)")"
SYS_MODS="$(dirname "$(find "$BUILD" -name SystemPackage.swiftmodule | head -1)")"
SHIM_INC="$(find .build -name _SubprocessCShims -type d | head -1)/include"
CORE_OBJECTS="$(find "$BUILD" -name '*.o' ! -path '*ClientTests*')"

swiftc -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macosx26.0 -sdk "$(xcrun --show-sdk-path)" \
  -o "$OUT/coordtests" \
  CoordinatorTests/Harness/main.swift \
  CoordinatorTests/Harness/FontSettingsStub.swift \
  CoordinatorTests/SessionViewModelStub.swift \
  CoordinatorTests/CoordinatorNavigationTests.swift \
  Client/Accessibility/DisplayOptions.swift \
  Client/Views/CodeCopyButton.swift \
  Client/Views/MarkdownText.swift \
  Client/Views/RowMeasurement.swift \
  Client/Views/TextRowView.swift \
  Client/Views/ToolCallCardView.swift \
  Client/Views/TranscriptEntry+Measurement.swift \
  Client/Views/TranscriptView.swift \
  -I "$CORE_MODS" -I "$SUB_MODS" -I "$SYS_MODS" -I "$SHIM_INC" \
  -I "$OUT/mod" -L "$OUT" -lXCTest \
  $CORE_OBJECTS

# 3. Run (DYLD_LIBRARY_PATH so the stub XCTest dylib resolves).
DYLD_LIBRARY_PATH="$OUT" "$OUT/coordtests"
