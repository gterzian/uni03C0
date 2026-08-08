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
        // The requested spec-site prefill, plus the model provider and the
        // code sources (registries/git hosts) a coding agent needs to work.
        XCTAssertEqual(defaults.allowedHosts, [
            "deepseek.com",
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

    func testPolicyNetworkIsLoopbackOnly() {
        // The seatbelt profile language cannot express hostnames, so the
        // policy never mentions the domain list — enforcement lives in the
        // whitelist proxy. The sandbox allows loopback only.
        let settings = SandboxSettings(readOnlyPaths: [], allowedHosts: ["whatwg.org"])
        let source = source(settings: settings)
        XCTAssertTrue(source.contains("(allow network-outbound (remote ip \"localhost:*\"))"))
        XCTAssertFalse(source.contains("whatwg.org"))
    }

    func testPolicyHasDyldBootstrapSupport() {
        let source = source(settings: .init(readOnlyPaths: [], allowedHosts: []))
        XCTAssertTrue(source.contains("/System/Cryptexes/OS"))
        XCTAssertTrue(source.contains("SYS_map_with_linking_np"))
    }

    func testCanonicalizeExpandsTilde() {
        let expanded = SandboxPolicy.canonicalize("~/.cargo")
        XCTAssertEqual(expanded, NSHomeDirectory() + "/.cargo")
    }
}

final class WhitelistTests: XCTestCase {
    func testExactAndSubdomainMatch() {
        let whitelist = WhitelistProxy.Whitelist(hosts: ["whatwg.org", "w3c.github.io"])
        XCTAssertTrue(whitelist.allows("whatwg.org"))
        XCTAssertTrue(whitelist.allows("html.spec.whatwg.org"))
        XCTAssertTrue(whitelist.allows("www.w3c.github.io"))
    }

    func testNonWhitelistedHostsDenied() {
        let whitelist = WhitelistProxy.Whitelist(hosts: ["whatwg.org"])
        XCTAssertFalse(whitelist.allows("evil.com"))
        // Suffix match must respect the dot boundary
        XCTAssertFalse(whitelist.allows("notwhatwg.org"))
        XCTAssertFalse(whitelist.allows("whatwg.org.evil.com"))
    }

    func testPortsAndCaseStripped() {
        let whitelist = WhitelistProxy.Whitelist(hosts: ["whatwg.org"])
        XCTAssertTrue(whitelist.allows("whatwg.org:443"))
        XCTAssertTrue(whitelist.allows("WHATWG.ORG"))
        XCTAssertTrue(whitelist.allows("spec.whatwg.org:80"))
    }

    func testIPv6BracketsStripped() {
        let whitelist = WhitelistProxy.Whitelist(hosts: ["::1"])
        XCTAssertTrue(whitelist.allows("[::1]:443"))
    }
}
