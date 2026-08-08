import Foundation

/// Builds the Seatbelt policy text for the agent's subprocess — Strategy A
/// from the sandbox design note (the process sandboxes itself).
///
/// The app does **not** apply the sandbox to the child directly: the design
/// note's Strategy B (`sandbox_apply(profile, pid)`) is unreliable on this
/// macOS — when `task_for_pid` fails it silently falls back to sandboxing the
/// *caller* (verified: it sandboxed the app itself). Instead, a tiny launcher
/// executable (`SandboxLauncher`) calls `sandbox_init` on itself and execs
/// the agent; the sandbox survives exec and is inherited by everything the
/// agent spawns.
///
/// The policy is also constrained by what the profile language supports on
/// this macOS, verified empirically:
/// - Network filters accept only `*` and `localhost` as hosts — no IP
///   literals, no hostnames. So network is loopback-only and the domain
///   whitelist is enforced by the app-side `WhitelistProxy`.
/// - dyld aborts during startup unless Apple's dyld-support rules (cryptex
///   graft points + special syscalls) are included — taken from
///   /System/Library/Sandbox/Profiles/dyld-support.sb.
public enum SandboxPolicy {
    /// Builds the Seatbelt policy text for one project.
    ///
    /// The scaffold is fixed; `settings` contributes the user's read+write
    /// dev directories.
    public static func source(
        project: String,
        home: String = NSHomeDirectory(),
        settings: SandboxSettings
    ) -> String {
        let projectPath = canonicalize(project)
        let devPaths = settings.readOnlyPaths.map { canonicalize($0, home: home) }
        let devReadWrite = devPaths.map { "(subpath \"\($0)\")" }.joined(separator: " ")
        let devExec = devPaths.map { "(subpath \"\($0)\")" }.joined(separator: " ")

        // Directory-entry reads for the path components *above* the allowed
        // subtrees. node's realpathSync lstats every component (e.g. `/opt`
        // when resolving `/opt/homebrew/…`), and a denied lstat of an
        // ancestor kills startup with EPERM.
        let ancestorTargets = ([projectPath, "\(home)/.pi"] + devPaths + [
            "/usr/local", "/opt/homebrew", "/usr/bin", "/bin", "/usr/lib",
            "/System/Library", "/Library/Frameworks", "/dev",
            "/private/tmp", "/private/var/tmp",
            "/private/var", "/private/etc", "/usr/share", "/usr/libexec",
            "/Library/Apple", "/Library/Preferences", "\(home)/Library/Preferences",
        ]).map { "(path-ancestors \"\($0)\")" }.joined(separator: " ")

        return """
        (version 1)
        (deny default)

        ;; Project workspace — read + write (+ executable mapping for built binaries)
        (allow file-read* (subpath "\(projectPath)"))
        (allow file-write* (subpath "\(projectPath)"))
        (allow file-map-executable (subpath "\(projectPath)"))

        ;; pi's own data directory — read + write (sessions, config)
        (allow file-read* (subpath "\(home)/.pi"))
        (allow file-write* (subpath "\(home)/.pi"))

        ;; User-configured development directories — read + write
        (allow file-read* \(devReadWrite))
        (allow file-write* \(devReadWrite))
        (allow file-map-executable \(devExec))

        ;; Temp — read + write. Both the literal /tmp and the real /private/tmp:
        ;; the seatbelt matches the path as given and does not resolve the
        ;; symlink, so tools writing to /tmp literally need that entry too.
        (allow file-read* (subpath "/tmp") (subpath "/private/tmp") (subpath "/private/var/tmp"))
        (allow file-write* (subpath "/tmp") (subpath "/private/tmp") (subpath "/private/var/tmp"))

        ;; macOS development tooling (Xcode command-line tools). Verified
        ;; empirically — without these, build tools fail inside the sandbox:
        ;; - /var: `xcode-select` reads /var/select/developer_dir. /var is a
        ;;   symlink to /private/var, and a (subpath "/var/select") rule does
        ;;   NOT grant access to /var itself — the symlink read is denied, so
        ;;   every /var/… path fails. Cover the root: (subpath "/var") plus
        ;;   (subpath "/private/var") for the real spelling.
        ;; - /var/folders: the per-user temp dir macOS sets $TMPDIR to; clang
        ;;   refuses to create temp files when it is denied (write rule below).
        ;; - /etc: system configs (hosts, shells, resolv.conf). Symlink to
        ;;   /private/etc — both spellings listed.
        ;; - /usr/share, /usr/libexec: system data, helpers, headers.
        ;;   (/usr/include does not exist on macOS 26 — headers live in the
        ;;   SDK under /Library/Developer.)
        ;; - /Library/Apple: Apple support data.
        ;; - Preferences (user + system): the Xcode license check reads
        ;;   ~/Library/Preferences/com.apple.dt.Xcode.plist directly (not via
        ;;   cfprefsd); without read access xcodebuild exits with "You have
        ;;   not agreed to the Xcode license agreements" even after the user
        ;;   accepted it.
        (allow file-read* file-test-existence
          (subpath "/var") (subpath "/private/var")
          (subpath "/etc") (subpath "/private/etc")
          (subpath "/usr/share") (subpath "/usr/libexec")
          (subpath "/Library/Apple")
          (subpath "\(home)/Library/Preferences") (subpath "/Library/Preferences"))
        (allow file-write* (subpath "/var/folders") (subpath "/private/var/folders"))
        (allow file-map-executable (subpath "/usr/libexec") (subpath "/usr/share"))

        ;; System read (+ executable mapping for dyld / runtimes)
        (allow file-read* (subpath "/usr/local") (subpath "/opt/homebrew") (subpath "/usr/bin") (subpath "/bin") (subpath "/usr/lib") (subpath "/System/Library") (subpath "/Library/Frameworks") (subpath "/dev"))
        (allow file-write* (literal "/dev/null"))
        (allow file-map-executable (subpath "/usr/local") (subpath "/opt/homebrew") (subpath "/usr/bin") (subpath "/bin") (subpath "/usr/lib") (subpath "/System/Library") (subpath "/Library/Frameworks") (subpath "/dev"))

        ;; Directory-entry reads for path components above the allowed
        ;; subtrees (node's realpathSync lstats each ancestor).
        (allow file-read* \(ancestorTargets))

        ;; dyld bootstrap — cryptex graft points (where the dyld shared cache
        ;; actually lives on modern macOS) plus the special syscalls/fcntls
        ;; dyld needs. Without these, dyld aborts during startup. Taken from
        ;; Apple's own /System/Library/Sandbox/Profiles/dyld-support.sb.
        (allow file-read* file-test-existence file-map-executable
          (subpath "/System/Volumes/Preboot/Cryptexes/App/System") (subpath "/System/Volumes/Preboot/Cryptexes/Incoming/OS") (subpath "/System/Volumes/Preboot/Cryptexes/OS") (subpath "/System/Cryptexes/App") (subpath "/System/Cryptexes/OS"))
        (allow file-read* file-test-existence
          (path-ancestors "/System/Volumes/Preboot/Cryptexes/App/System") (path-ancestors "/System/Volumes/Preboot/Cryptexes/Incoming/OS") (path-ancestors "/System/Volumes/Preboot/Cryptexes/OS") (path-ancestors "/System/Cryptexes/App") (path-ancestors "/System/Cryptexes/OS"))
        (allow syscall-unix (syscall-number SYS___mac_syscall) (syscall-number SYS_getfsstat SYS_getfsstat64) (syscall-number SYS_map_with_linking_np))
        (allow system-fcntl (fcntl-command F_ADDFILESIGS_RETURN F_CHECK_LV F_GETPATH))
        (with-filter (mac-policy-name "Sandbox") (allow system-mac-syscall (mac-syscall-number 2)))
        (allow file-read* file-test-existence (literal "/"))
        (allow syscall-unix (syscall-number SYS_open) (syscall-number SYS_openat))
        (allow syscall-unix (syscall-number SYS_fstatat SYS_fstatat64))
        (allow syscall-unix (syscall-number SYS_dup))

        ;; Processes — spawn build tools; signal self and siblings
        (allow process-fork)
        (allow process-exec)
        (allow process-info*)
        (allow signal (target self) (target others))

        ;; IPC / misc
        (allow sysctl-read)
        (allow file-ioctl)
        (allow mach-lookup
          (global-name "com.apple.system.logger")
          (global-name "com.apple.system.opendirectoryd.libinfo")
          (global-name "com.apple.mDNSResponder"))

        ;; Network — loopback only. The app's whitelist proxy (WhitelistProxy)
        ;; on 127.0.0.1 is the sole internet egress; anything that ignores the
        ;; proxy env simply cannot connect (fail-closed).
        (allow network-outbound (remote ip "localhost:*"))
        """
    }

    /// Resolves a user-entered path: expands `~`, then resolves symlinks
    /// (`/tmp` → `/private/tmp`) — seatbelt matches real paths. `home` is
    /// injectable for tests.
    public static func canonicalize(_ path: String, home: String = NSHomeDirectory()) -> String {
        let expanded: String
        if path == "~" {
            expanded = home
        } else if path.hasPrefix("~/") {
            expanded = home + path.dropFirst(1)
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }
}
