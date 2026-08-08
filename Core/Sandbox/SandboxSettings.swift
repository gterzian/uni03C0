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
            "/opt/local",                  // MacPorts
            "~/Library/Android/sdk",       // Android SDK
        ],
        allowedHosts: [
            // The model provider — required for the agent to reach its model.
            "deepseek.com",
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
        return SandboxSettings(readOnlyPaths: paths, allowedHosts: hosts)
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

    public static func serialize(_ entries: [String]) -> String {
        entries.joined(separator: "\n")
    }
}
