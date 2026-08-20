// swift-tools-version:6.2
// A SwiftPM test harness for building and running the CORE unit tests with
// plain `swift` — the ONLY way to build inside the app's Seatbelt sandbox.
//
// `xcodebuild` cannot work there: its "Resolve Package Graph" step runs SPM's
// manifest sandbox (`sandbox-exec`), which the Seatbelt policy denies
// (sandbox_apply: Operation not permitted — no policy rule can lift it).
// SwiftPM's own manifest evaluation has the same problem unless disabled:
//
//     swift test --disable-sandbox
//
// `--disable-sandbox` skips the nested sandbox-exec; the dependencies resolve
// from the local SCM cache (populated by `./run.sh` / xcodebuild in the
// terminal) or, on a fresh machine, through the app's whitelist proxy (GitHub
// is on the default allowlist). The harness links the REAL Core framework and
// the REAL XCTest overlay, and auto-discovers async test methods — no stubs.
//
// RenderingTests are deliberately NOT here: they compile the AppKit renderer
// (Client target) whose sources assume the Client target's MainActor default
// isolation (project.yml). Under Swift 6 language mode that default isolation
// conflicts with real XCTest's nonisolated ObjC `setUp`/init overrides (the
// compiler rejects MainActor-isolated overrides of them), so they keep the
// documented swiftc + stub-XCTest route in AGENTS.md instead — the stub is
// compiled under the same isolation, sidestepping the mismatch.
import PackageDescription

let package = Package(
    name: "ClientTests",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
        // Declared explicitly so `import System` in Core/ProcessController
        // resolves even under MemberImportVisibility (swift-subprocess also
        // depends on it, same URL → same identity, resolved once).
        .package(url: "https://github.com/apple/swift-system", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Core"
        ),
        .testTarget(
            name: "ClientTests",
            dependencies: ["Core"],
            path: "ClientTests"
        ),
    ]
)
