import XCTest
@testable import Core

/// Tests for the whitelist logic behind the loopback proxy — the security
/// boundary that decides which hosts the agent may reach. Pure string logic.
final class WhitelistTests: XCTestCase {

    private func whitelist(_ hosts: [String]) -> WhitelistProxy.Whitelist {
        WhitelistProxy.Whitelist(hosts: hosts)
    }

    func testExactHostAllowed() {
        let wl = whitelist(["github.com"])
        XCTAssertTrue(wl.allows("github.com"))
        XCTAssertFalse(wl.allows("github.org"))
    }

    func testSubdomainAllowed() {
        let wl = whitelist(["github.com"])
        XCTAssertTrue(wl.allows("api.github.com"))
        XCTAssertTrue(wl.allows("codeload.github.com"))
        XCTAssertTrue(wl.allows("deep.sub.github.com"))
    }

    func testSubdomainSuffixIsNotPartialName() {
        let wl = whitelist(["github.com"])
        // "mygithub.com" must NOT match "github.com" via suffix.
        XCTAssertFalse(wl.allows("mygithub.com"))
        XCTAssertFalse(wl.allows("notgithub.com"))
    }

    func testCaseInsensitive() {
        let wl = whitelist(["GitHub.COM"])
        XCTAssertTrue(wl.allows("github.com"))
        XCTAssertTrue(wl.allows("API.GITHUB.COM"))
    }

    func testPortStripped() {
        let wl = whitelist(["example.com"])
        XCTAssertTrue(wl.allows("example.com:443"))
        XCTAssertTrue(wl.allows("api.example.com:8080"))
    }

    func testHostWithNonNumericColonIsIPv6LikeAndKept() {
        // A bare IPv6 (multiple colons) is not treated as host:port.
        XCTAssertEqual(WhitelistProxy.Whitelist.normalizeHost("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(WhitelistProxy.Whitelist.normalizeHost("[2001:db8::1]:443"), "2001:db8::1")
    }

    func testIPv6BracketedTargetAllowedWhenHostWhitelisted() {
        let wl = whitelist(["::1"])
        XCTAssertTrue(wl.allows("[::1]:443"))
        XCTAssertTrue(wl.allows("::1"))
    }

    func testEmptyOrWhitespaceHostRejected() {
        let wl = whitelist(["example.com"])
        XCTAssertFalse(wl.allows(""))
        XCTAssertFalse(wl.allows(" "))
    }

    func testHostNeverAllowed() {
        let wl = whitelist([])
        XCTAssertFalse(wl.allows("anything.com"))
    }

    func testLocalhostNotImpliedByWhitelist() {
        // Loopback is allowed at the sandbox level; the whitelist itself must
        // not silently grant it unless explicitly listed.
        let wl = whitelist(["example.com"])
        XCTAssertFalse(wl.allows("localhost"))
        XCTAssertFalse(wl.allows("127.0.0.1"))
    }

    func testNormalizationIsStoredAtInit() {
        let wl = whitelist(["Example.COM:443", "api.github.com"])
        XCTAssertTrue(wl.allows("example.com"))
        XCTAssertTrue(wl.allows("api.github.com"))
    }
}
