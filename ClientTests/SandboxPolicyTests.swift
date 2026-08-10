import Core
import XCTest

final class SandboxSettingsTests: XCTestCase {
    func testDefaultsCoverMacDevelopment() {
        let defaults = SandboxSettings.defaults
        XCTAssertFalse(defaults.readOnlyPaths.isEmpty)
        // Core language toolchains
        XCTAssertTrue(defaults.readOnlyPaths.contains("~/.cargo"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("~/.rustup"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("~/.nvm"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("~/.npm"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("~/.pyenv"))
        // Native macOS development
        XCTAssertTrue(defaults.readOnlyPaths.contains("/Library/Frameworks"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("/System/Library/Frameworks"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("/Applications/Xcode.app"))
        // Formal verification tooling (spec traces run from the agent).
        XCTAssertTrue(defaults.readOnlyPaths.contains("/Applications/TLA+ Toolbox.app"))
        // Build output/caches and Homebrew (Intel) — writable dev dirs
        XCTAssertTrue(defaults.readOnlyPaths.contains("~/Library/Developer"))
        XCTAssertTrue(defaults.readOnlyPaths.contains("/usr/local"))
        // The requested spec-site prefill, plus the model provider and the
        // code sources (registries/git hosts) a coding agent needs to work,
        // and the subscription/OAuth hosts so a terminal `/login` also works
        // from the app.
        XCTAssertEqual(defaults.allowedHosts, [
            "deepseek.com",
            "api.deepseek.com", "api.anthropic.com", "api.openai.com",
            "generativelanguage.googleapis.com",
            "claude.ai", "platform.claude.com", "chatgpt.com",
            "auth.openai.com", "githubcopilot.com", "x.ai", "openrouter.ai",
            "whatwg.org", "w3c.org", "w3c.github.io",
            "github.com", "githubusercontent.com",
            "crates.io", "npmjs.org", "pypi.org", "files.pythonhosted.org",
            "proxy.golang.org", "static.rust-lang.org", "nodejs.org", "ghcr.io",
            "docs.rs", "doc.rust-lang.org", "developer.mozilla.org", "developer.apple.com",
        ])
        // Subdomain coverage is what makes the entries useful: api.github.com
        // and static.crates.io must match without being listed themselves.
        let whitelist = WhitelistProxy.Whitelist(hosts: defaults.allowedHosts)
        XCTAssertTrue(whitelist.allows("api.github.com"))
        XCTAssertTrue(whitelist.allows("static.crates.io"))
        XCTAssertTrue(whitelist.allows("registry.npmjs.org"))
        XCTAssertTrue(whitelist.allows("raw.githubusercontent.com"))
        // Model provider endpoints listed explicitly must match exactly.
        XCTAssertTrue(whitelist.allows("api.deepseek.com"))
        XCTAssertTrue(whitelist.allows("api.anthropic.com"))
        XCTAssertTrue(whitelist.allows("api.openai.com"))
        XCTAssertTrue(whitelist.allows("generativelanguage.googleapis.com"))
    }

    func testParseTrimsAndDropsComments() {
        let entries = SandboxSettings.parse("""
        ~/.cargo

          ~/.rustup   
        # a comment
        /Library/Frameworks
        """)
        XCTAssertEqual(entries, ["~/.cargo", "~/.rustup", "/Library/Frameworks"])
    }

    func testParseEmpty() {
        XCTAssertEqual(SandboxSettings.parse(""), [])
        XCTAssertEqual(SandboxSettings.parse("   \n# only a comment\n"), [])
    }

    func testSerializeRoundTrip() {
        let entries = ["~/.cargo", "~/.rustup"]
        XCTAssertEqual(SandboxSettings.parse(SandboxSettings.serialize(entries)), entries)
    }
}

final class SandboxPolicyTests: XCTestCase {
    private let home = "/Users/tester"

    private func source(settings: SandboxSettings) -> String {
        SandboxPolicy.source(project: "/Users/tester/projects/example", home: home, settings: settings)
    }

    func testPolicyIsDefaultDeny() {
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(deny default)"))
        XCTAssertTrue(source.contains("(version 1)"))
    }

    func testPolicyAllowsProjectReadWrite() {
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow file-read* (subpath \"/Users/tester/projects/example\"))"))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/Users/tester/projects/example\"))"))
    }

    func testPolicyAllowsPiDataDir() {
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow file-read* (subpath \"/Users/tester/.pi\"))"))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/Users/tester/.pi\"))"))
    }

    func testPolicyAllowsGitConfigReadOnly() {
        // Read-only git (status/log/diff) needs the user's git config,
        // credentials, and SSH material — but never writes to them.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(literal \"/Users/tester/.gitconfig\")"))
        XCTAssertTrue(source.contains("(literal \"/Users/tester/.gitattributes\")"))
        XCTAssertTrue(source.contains("(literal \"/Users/tester/.gitignore_global\")"))
        XCTAssertTrue(source.contains("(literal \"/Users/tester/.git-credentials\")"))
        XCTAssertTrue(source.contains("(subpath \"/Users/tester/.config/git\")"))
        XCTAssertTrue(source.contains("(subpath \"/Users/tester/.ssh\")"))
        // No write access to git config: the agent never runs git config
        // writes or mutates credentials.
        XCTAssertFalse(source.contains("file-write* (literal \"/Users/tester/.gitconfig\""))
        XCTAssertFalse(source.contains("file-write* (subpath \"/Users/tester/.ssh\""))
        // Ancestors for the new roots (node lstats every component).
        XCTAssertTrue(source.contains("(path-ancestors \"/Users/tester/.gitconfig\")"))
        XCTAssertTrue(source.contains("(path-ancestors \"/Users/tester/.config/git\")"))
        XCTAssertTrue(source.contains("(path-ancestors \"/Users/tester/.ssh\")"))
    }

    func testPolicyIncludesUserDevPathsExpanded() {
        let settings = SandboxSettings(readOnlyPaths: ["~/.cargo", "/Library/Frameworks"], allowedHosts: [])
        let source = source(settings: settings)
        XCTAssertTrue(source.contains("(subpath \"/Users/tester/.cargo\")"))
        XCTAssertTrue(source.contains("(subpath \"/Library/Frameworks\")"))
        // Read + write both granted
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/Users/tester/.cargo\")"))
    }

    func testPolicyAllowsLiteralTmpAndPrivateTmp() {
        // The seatbelt matches paths as given and does not resolve the /tmp
        // symlink: tools writing to /tmp literally need the literal entry.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\"))"))
        XCTAssertTrue(source.contains("(allow file-read* (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\"))"))
    }

    func testPolicyAllowsXcodeCommandLineTooling() {
        // macOS dev tooling, verified empirically: xcode-select reads the
        // /var/select developer-dir symlink, compilers write $TMPDIR
        // (/var/folders), headers/configs live in /usr/share, /usr/libexec,
        // /etc. Note: /var and /etc are symlinks, so the ROOT itself must be
        // listed — a (subpath "/var/select") rule does not grant reading the
        // /var symlink, so every /var/… path would still fail.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(subpath \"/var\") (subpath \"/private/var\")"))
        XCTAssertTrue(source.contains("(subpath \"/etc\") (subpath \"/private/etc\")"))
        XCTAssertTrue(source.contains("(subpath \"/usr/share\") (subpath \"/usr/libexec\")"))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/var/folders\") (subpath \"/private/var/folders\"))"))
        // Preferences: the Xcode license check reads the plist directly.
        XCTAssertTrue(source.contains("(subpath \"/Users/tester/Library/Preferences\") (subpath \"/Library/Preferences\")"))
        // Ancestors for the new roots, so an lstat of /private/var succeeds.
        XCTAssertTrue(source.contains("(path-ancestors \"/private/var\")"))
        XCTAssertTrue(source.contains("(path-ancestors \"/private/etc\")"))
        XCTAssertTrue(source.contains("(path-ancestors \"/usr/share\")"))
    }

    func testPolicyNetworkIsLoopbackOnly() {
        // The seatbelt profile language cannot express hostnames, so the
        // policy never mentions the domain list — enforcement lives in the
        // whitelist proxy. The sandbox allows loopback only.
        let settings = SandboxSettings(readOnlyPaths: [], allowedHosts: ["whatwg.org"])
        let source = source(settings: settings)
        XCTAssertTrue(source.contains("(allow network-outbound (remote ip \"localhost:*\"))"))
        // Inbound is loopback too — local test servers (WPT, WebDriver, TLA+)
        // bind/accept on 127.0.0.1 inside the sandbox.
        XCTAssertTrue(source.contains("(allow network-inbound (local ip \"localhost:*\"))"))
        XCTAssertFalse(source.contains("whatwg.org"))
    }

    func testPolicyHasDyldBootstrapSupport() {
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("/System/Cryptexes/OS"))
        XCTAssertTrue(source.contains("SYS_map_with_linking_np"))
    }

    func testPolicyAllowsNestedSandboxing() {
        // SPM package resolution runs sandbox-exec; the outer profile must
        // permit the sandbox module's mac syscalls or xcodebuild's package
        // resolution aborts with "sandbox_apply: Operation not permitted".
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow system-mac-syscall)"))
    }

    func testPolicyAllowsMachIpc() {
        // The agent runs arbitrary tools whose IPC uses dynamic Mach service
        // names (ipc-channel bootstrap names are random per connection), so
        // mach lookup/register are allowed in general, not name-whitelisted.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow mach-lookup)"))
        XCTAssertTrue(source.contains("(allow mach-register)"))
        XCTAssertFalse(source.contains("global-name"))
    }

    func testPolicyAllowsGpuMetal() {
        // wgpu/Metal enumerate adapters and create devices via IOKit GPU
        // services (AGX on Apple Silicon); without iokit-open rules adapter
        // enumeration finds nothing ("metal found no adapters").
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(iokit-registry-entry-class-prefix \"AGX\" \"AGPM\" \"IOGPU\" \"AMDRadeon\" \"IntelAccelerator\")"))
        XCTAssertTrue(source.contains("iokit-user-client-class-regex"))
        XCTAssertTrue(source.contains("(allow iokit-get-properties)"))
        XCTAssertTrue(source.contains("(iokit-registry-entry-class \"IOSurfaceRoot\")"))
    }

    func testPolicyAllowsPosixIpc() {
        // Python multiprocessing uses POSIX named semaphores + shared memory;
        // without these, multiprocessing.Lock()/SharedMemory raise
        // PermissionError "Operation not permitted".
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow ipc-posix-sem)"))
        XCTAssertTrue(source.contains("(allow ipc-posix-shm)"))
    }

    func testPolicyAllowsSignaling() {
        // `(target others)` alone does NOT cover the session's own children
        // (same sandbox context) — kill on them is denied with EPERM. Both
        // same-sandbox and others are needed for kill/pkill in scripts.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(allow signal (target self) (target others) (target same-sandbox))"))
    }

    func testPolicyAllowsJavaRuntime() {
        // The TLA+ verification runs TLC via system java (Temurin under
        // /Library/Java/JavaVirtualMachines); without /Library/Java read +
        // exec mapping the java stub reports "Unable to locate a Java Runtime".
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(subpath \"/Library/Java\")"))
        XCTAssertTrue(source.contains("(path-ancestors \"/Library/Java\")"))
    }

    func testCanonicalizeExpandsTilde() {
        let expanded = SandboxPolicy.canonicalize("~/.cargo")
        XCTAssertEqual(expanded, NSHomeDirectory() + "/.cargo")
    }

    func testPolicyDenialMessagesArePresent() {
        // Denials fire `with message` explanations to the unified log so the
        // operator can tell the agent where the error comes from.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("(deny default (with message"))
        XCTAssertTrue(source.contains("default-deny Seatbelt sandbox"))
        XCTAssertTrue(source.contains("xcodebuild / SwiftPM CANNOT resolve Swift packages"))
        XCTAssertTrue(source.contains("(deny network-outbound (with message"))
        XCTAssertTrue(source.contains("(deny file-write* (with message"))
    }

    func testPolicyDenialMessagesDoNotOverrideAllows() {
        // The message-denies sit BEFORE the allows, so the later allows still
        // win (last matching rule) — the loopback network and workspace
        // file-write grants must remain effective.
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        let networkDeny = source.range(of: "(deny network-outbound (with message")!
        let networkAllow = source.range(of: "(allow network-outbound (remote ip \"localhost:*\"))")!
        XCTAssertLessThan(networkDeny.lowerBound, networkAllow.lowerBound)
        let writeDeny = source.range(of: "(deny file-write* (with message")!
        let writeAllow = source.range(of: "(allow file-write* (subpath \"/Users/tester/projects/example\"))")!
        XCTAssertLessThan(writeDeny.lowerBound, writeAllow.lowerBound)
    }
}
