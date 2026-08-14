import Foundation

/// The user-tunable part of the sandbox policy, persisted in UserDefaults.
///
/// Two fields, both plain-text lists (one entry per line):
///
/// - `readOnlyPaths`: development directories the agent may read *and write*
///   (toolchain homes, package caches, framework dirs, Xcode …). The policy
///   grants these read+write so cold builds can populate caches. System dirs
///   like `/usr`, `/System/Library` and the dyld cryptexes are part of the
///   fixed policy scaffold, not this list.
/// - `allowedHosts`: the only internet hosts the agent may reach. The
///   seatbelt profile on modern macOS cannot express hostnames (only `*` and
///   `localhost` — verified empirically), so enforcement happens in the app:
///   the sandbox allows loopback traffic only, and a loopback whitelist proxy
///   (`WhitelistProxy`) is the sole egress. Subdomains of each listed host are
///   included.
public struct SandboxSettings: Sendable, Equatable, Codable {
    public var readOnlyPaths: [String]
    public var allowedHosts: [String]

    public init(readOnlyPaths: [String], allowedHosts: [String]) {
        self.readOnlyPaths = readOnlyPaths
        self.allowedHosts = allowedHosts
    }

    /// Sensible out-of-the-box values: everything needed to code on macOS for
    /// the common languages plus native macOS development (Xcode, SDKs,
    /// frameworks). Shown prefilled on first run; the user edits freely.
    public static let defaults = SandboxSettings(
        readOnlyPaths: [
            "~/.cargo",                    // Rust: crate registry + git cache
            "~/.rustup",                   // Rust toolchains
            "~/.nvm",                      // Node version manager
            "~/.npm",                      // npm cache
            "~/.bun",                      // Bun
            "~/.deno",                     // Deno
            "~/.pyenv",                    // Python versions
            "~/.local",                    // pip --user installs, misc
            "~/.cache",                    // Linux-style caches (pip, uv, …)
            "~/Library/Caches",            // macOS caches (go-build, swiftpm, …)
            "~/Library/Python",            // pip --user on macOS
            "~/.gem",                      // Ruby gems
            "~/.swiftpm",                  // Swift Package Manager
            "~/.gradle",                   // Gradle
            "~/.m2",                       // Maven
            "~/.ivy2",                     // sbt
            "~/go",                        // Go: GOPATH + module cache
            "~/.node_modules",             // global node modules
            "/Library/Frameworks",         // installed frameworks
            "/System/Library/Frameworks",  // Apple frameworks
            "/Library/Developer",          // Xcode shared data
            "/Library/Developer/CommandLineTools",
            "/Applications/Xcode.app",     // Xcode: SDKs, toolchains, swiftc
            "/Applications/TLA+ Toolbox.app", // TLA+ formal verification (spec checks)
            "/opt/local",                  // MacPorts
            "/usr/local",                  // Homebrew (Intel) / local installs
            "~/Library/Developer",          // Xcode DerivedData, module caches
            "~/Library/Android/sdk",       // Android SDK
        ],
        allowedHosts: [
            // Model providers — the hosts the agent reaches its models through.
            "deepseek.com",                 // DeepSeek
            "api.deepseek.com",             // DeepSeek API
            "api.anthropic.com",            // Anthropic
            "api.openai.com",               // OpenAI
            "generativelanguage.googleapis.com", // Google Gemini
            // Subscription / OAuth hosts — so a provider logged in from the
            // terminal (`pi` + `/login`, which stores tokens in
            // ~/.pi/agent/auth.json) also works from the app: the same
            // auth.json is read at spawn, and these are the API + OAuth
            // token-refresh hosts the subscriptions need (Claude Pro/Max,
            // ChatGPT Plus/Pro via Codex, GitHub Copilot, xAI, OpenRouter).
            "claude.ai",                    // Claude subscription OAuth
            "platform.claude.com",          // Anthropic OAuth token refresh
            "chatgpt.com",                  // OpenAI Codex (ChatGPT subscription)
            "auth.openai.com",              // OpenAI OAuth
            "githubcopilot.com",            // GitHub Copilot API + proxy
            "x.ai",                         // xAI (Grok/X subscription) API + OAuth
            "openrouter.ai",                // OpenRouter OAuth-minted keys
            // Web-spec sites (the original prefill).
            "whatwg.org",
            "w3c.org",
            "w3c.github.io",
            // Code sources: without these the agent cannot fetch dependencies,
            // clone repos, or install toolchains. Subdomains of each entry are
            // included automatically (api.github.com, static.crates.io,
            // registry.npmjs.org, …). githubusercontent.com is separate from
            // github.com — raw.githubusercontent.com and release assets live
            // there, not under github.com.
            "github.com",
            "githubusercontent.com",
            "github.io",                  // GitHub Pages (docs sites, project pages)
            "crates.io",                 // cargo registry
            "npmjs.org",                 // npm registry
            "pypi.org",                  // pip
            "files.pythonhosted.org",    // pip wheels (not a subdomain of pypi.org)
            "proxy.golang.org",          // Go module proxy
            "static.rust-lang.org",      // rustup toolchain downloads
            "nodejs.org",                // node downloads
            "ghcr.io",                   // Homebrew bottles / containers
            // Documentation.
            "docs.rs",                   // Rust crate docs
            "doc.rust-lang.org",         // Rust language docs
            "developer.mozilla.org",     // MDN web docs
            "developer.apple.com",       // Apple developer docs
        ]
    )

    // MARK: - Persistence

    private static let pathsKey = "sandbox.readOnlyPaths"
    private static let hostsKey = "sandbox.allowedHosts"

    public static func load() -> SandboxSettings {
        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: pathsKey) ?? []
        let hosts = defaults.stringArray(forKey: hostsKey) ?? []
        if paths.isEmpty && hosts.isEmpty { return Self.defaults }
        var settings = SandboxSettings(readOnlyPaths: paths, allowedHosts: hosts)
        // Normalize stored host entries: a URL pasted into the domains field
        // (https://example.com/path) must be enforced as its bare host
        // (example.com). Any raw entries written by an earlier app version are
        // cleaned here once, so they take effect without waiting for a re-save.
        let normalizedHosts = Self.dedupe(settings.allowedHosts.compactMap { host in
            let normalized = Self.normalizeHost(host)
            return normalized.isEmpty ? nil : normalized
        })
        if normalizedHosts != settings.allowedHosts {
            settings.allowedHosts = normalizedHosts
            settings.save()
        }
        // One-shot migration: saved lists written by an older app version may
        // predate default entries added since (e.g. ~/Library/Developer for
        // Xcode builds — without it xcodebuild cannot write DerivedData inside
        // the sandbox). Merge in anything the current defaults carry that the
        // saved list lacks, and persist so the merge applies once, not on
        // every launch. The user's own edits still win afterwards: their next
        // save replaces the list wholesale.
        let missingPaths = Self.defaults.readOnlyPaths.filter { !settings.readOnlyPaths.contains($0) }
        let missingHosts = Self.defaults.allowedHosts.filter { !settings.allowedHosts.contains($0) }
        if !missingPaths.isEmpty || !missingHosts.isEmpty {
            settings.readOnlyPaths.append(contentsOf: missingPaths)
            settings.allowedHosts.append(contentsOf: missingHosts)
            settings.save()
        }
        return settings
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(readOnlyPaths, forKey: Self.pathsKey)
        defaults.set(allowedHosts, forKey: Self.hostsKey)
    }

    // MARK: - Text editing

    /// Parses one entry per line: trims whitespace, drops blank lines and
    /// `#`-prefixed comments. Used by both editor fields.
    public static func parse(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            return trimmed
        }
    }

    /// Parses one host per line for the allowed-domains field. Accepts bare
    /// domains, `host:port`, and full URLs — whatever the user pastes — and
    /// reduces each line to its bare lowercase host (scheme, userinfo, port,
    /// path, query and fragment stripped). Blank lines and `#` comments are
    /// dropped, as are lines that yield no host.
    public static func parseHosts(_ text: String) -> [String] {
        dedupe(text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            let host = normalizeHost(trimmed)
            return host.isEmpty ? nil : host
        })
    }

    /// Reduces a pasted entry — full URL, bare domain, `host:port`, or
    /// `[v6]:port` — to its bare lowercase hostname. Returns "" when nothing
    /// host-like remains (so the line is dropped by `parseHosts`).
    public static func normalizeHost(_ entry: String) -> String {
        var s = entry.trimmingCharacters(in: .whitespaces).lowercased()
        // Strip the scheme: "https://example.com/path" → "example.com/path".
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
        }
        // Strip userinfo: "user:pass@example.com" → "example.com".
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        // Cut path / query / fragment.
        for marker in ["/", "?", "#"] {
            if let idx = s.firstIndex(of: Character(marker)) {
                s = String(s[..<idx])
            }
        }
        // Strip a ":port" (or "[v6]:port") suffix.
        if s.hasPrefix("[") {
            if let end = s.firstIndex(of: "]") {
                s = String(s[s.index(after: s.startIndex)..<end])
            }
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.lastIndex(of: ":") {
            let after = s[s.index(after: colon)...]
            if !after.isEmpty && after.allSatisfy(\.isNumber) {
                s = String(s[..<colon])
            }
        }
        return s
    }

    /// Ordered-unique: keeps first occurrences, drops later duplicates.
    private static func dedupe(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    public static func serialize(_ entries: [String]) -> String {
        entries.joined(separator: "\n")
    }
}
