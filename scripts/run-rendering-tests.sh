#!/bin/bash
# Builds and runs the RenderingTests — the AppKit renderer (MarkdownText,
# TranscriptText/TextRowView, CodeCopyButton) — using plain swiftc + the stub
# XCTest module. This is the only route that works inside the app's Seatbelt
# sandbox, and (per AGENTS.md) the only route that works at all for these
# tests: under Swift 6 with `-default-isolation MainActor`, an
# `override func setUp()` on a real `XCTestCase` is rejected against XCTest's
# nonisolated ObjC declarations, so the stub XCTest module — compiled with the
# SAME default isolation — is what makes the overrides legal.
#
# The stub XCTest + FontSettings stub are shared with the coordinator harness
# (CoordinatorTests/Harness); the runner is GENERATED from the test sources on
# every run, so it can never go stale as tests are added.
#
# Prerequisite: `swift test --disable-sandbox` has built the harness Core
# module at least once (`.build/arm64-apple-macosx/debug`), so the REAL Core is
# available to link against (TextRowView imports Core).
#
# TEST_FILTER=<substring> runs a subset.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=.build/arm64-apple-macosx/debug
OUT=/tmp/rendertests
mkdir -p "$OUT/mod"

# 1. The stub XCTest module, compiled under the SAME default isolation
#    (MainActor) as the renderer/test sources.
swiftc -emit-library -module-name XCTest -swift-version 6 \
  -default-isolation MainActor -target arm64-apple-macosx26.0 \
  -emit-module -emit-module-path "$OUT/mod" \
  CoordinatorTests/Harness/XCTestStub.swift -o "$OUT/libXCTest.dylib"

# 2. Generate the runner: pure-Swift test methods are not ObjC-visible, so
#    discovery cannot find them — each `final class …: XCTestCase` and its
#    `func test…()` methods are collected from the sources and invoked
#    explicitly (setUp before each, as real XCTest does).
RUNNER="$OUT/main.swift"
{
  echo "import AppKit"
  echo "import Foundation"
  echo "import XCTest"
  echo ""
  echo "// AppKit needs its shared application before views send actions"
  echo "// (NSButton.performClick routes through NSApp)."
  echo "_ = NSApplication.shared"
  echo ""
  echo "let tests: [(name: String, body: () -> Void)] = ["
  awk '
    /^final class [A-Za-z0-9_]+: XCTestCase/ { cls = $3; sub(":", "", cls) }
    /^    func test[A-Za-z0-9_]*\(\)/ {
      m = $2; sub(/\(\).*/, "", m)
      printf "    (\"%s.%s\", { let t = %s(); t.setUp(); t.%s(); t.tearDown() }),\n", cls, m, cls, m
    }
  ' RenderingTests/*.swift
  echo "]"
  cat <<'RUNNER_MAIN'

var totalFailures = 0
let filter = ProcessInfo.processInfo.environment["TEST_FILTER"]
var ran = 0
for test in tests where filter == nil || test.name.contains(filter!) {
    let before = __testFailures
    test.body()
    let failures = __testFailures - before
    totalFailures += failures
    ran += 1
    print("\(failures == 0 ? "PASS" : "FAIL") \(test.name)")
}
if totalFailures == 0 {
    print("All \(ran) rendering tests passed.")
} else {
    print("\(totalFailures) assertion(s) failed across \(ran) tests.")
    exit(1)
}
RUNNER_MAIN
} > "$RUNNER"

# 3. Compile the renderer + tests + runner into one binary, linking the real
#    Core module built by the SwiftPM harness. FontSettings is stubbed because
#    the @Observable macro's plugin server is blocked in the sandbox.
CORE_MODS="$BUILD/Modules"
SUB_MODS="$(dirname "$(find "$BUILD" -name Subprocess.swiftmodule | head -1)")"
SYS_MODS="$(dirname "$(find "$BUILD" -name SystemPackage.swiftmodule | head -1)")"
SHIM_INC="$(find .build -name _SubprocessCShims -type d | head -1)/include"
CORE_OBJECTS="$(find "$BUILD" -name '*.o' ! -path '*ClientTests*')"

swiftc -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macosx26.0 -sdk "$(xcrun --show-sdk-path)" \
  -o "$OUT/rendertests" \
  "$RUNNER" \
  CoordinatorTests/Harness/FontSettingsStub.swift \
  Client/Accessibility/DisplayOptions.swift \
  Client/Views/CodeCopyButton.swift \
  Client/Views/MarkdownText.swift \
  Client/Views/TextRowView.swift \
  RenderingTests/*.swift \
  -I "$CORE_MODS" -I "$SUB_MODS" -I "$SYS_MODS" -I "$SHIM_INC" \
  -I "$OUT/mod" -L "$OUT" -lXCTest \
  $CORE_OBJECTS

# 4. Run (DYLD_LIBRARY_PATH so the stub XCTest dylib resolves).
DYLD_LIBRARY_PATH="$OUT" "$OUT/rendertests"
