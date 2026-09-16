import Foundation

/// A click-time file reference: the parsed form of the `pi-file://` links the
/// agent is taught (via the bundled `file-reference-links` skill) to emit in
/// its responses when it wants to point the user at a file (and optionally a
/// line/range) in the session's folder.
///
/// This is the read-side twin of `CodeReference`'s render-side `promptText`,
/// and the two deliberately share only a convention, not code:
///
///     [Core/Renderer.swift:118-126](pi-file:///Core/Renderer.swift#L118-126)
///
/// `CodeReference` freezes what a human was looking at (absolute path +
/// snippet, never re-read from disk); this parses where the agent points and
/// always opens CURRENT disk content through the existing pane-load path. The
/// path is therefore RELATIVE to the session's `cwd`, forward-slash
/// separated — the same string space the agent's own `edit`/`write` tool
/// calls use — with no leading `/` and no `./`. There is no cross-project
/// ambiguity to defend against: the agent only ever names a file inside its
/// own session's folder.
///
/// Grammar (narrow on purpose — see the design doc §3):
/// - scheme `pi-file`, empty host (`pi-file:///…`, the triple-slash form).
/// - path: the cwd-relative path, percent-encoded where the filename needs it
///   (spaces, parens, `#`, `%`) — `URL.path` percent-decodes it back here.
/// - fragment `L<line>` or `L<start>-<end>`: 1-based, inclusive, matching
///   `CodeReference`'s line convention exactly. Omitted entirely → open the
///   file with no scroll target. A missing/malformed fragment is tolerated
///   (the file still opens); only a URL that isn't a `pi-file` link at all,
///   or one with an empty path, fails to parse.
public struct FileReferenceLink: Hashable, Sendable {
    /// The custom URL scheme. Unregistered, so if a click handler's scheme
    /// check is ever bypassed, `NSWorkspace` can't hand it to a browser.
    public static let scheme = "pi-file"

    /// Path relative to the session's `cwd`, forward-slash separated, no
    /// leading `/`.
    public let path: String
    /// 1-based, inclusive start line; nil for a whole-file reference.
    public let startLine: Int?
    /// 1-based, inclusive end line; nil when `startLine` is nil.
    public let endLine: Int?

    public init(path: String, startLine: Int? = nil, endLine: Int? = nil) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }

    /// Parses a `pi-file://` URL. `URL` has already percent-decoded the path
    /// and fragment, so a filename that needed encoding (`a b.swift`,
    /// `a(b).swift`, a literal `#`) comes back as the real character. Returns
    /// nil for a non-`pi-file` URL or one whose path is empty.
    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        var path = url.path
        // "pi-file:///a/b.swift" → "/a/b.swift" → "a/b.swift". The empty-host
        // triple-slash form means the path always starts at the root.
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        guard !path.isEmpty else { return nil }
        let (start, end) = Self.lines(fromFragment: url.fragment)
        self.init(path: path, startLine: start, endLine: end)
    }

    /// Parses the optional `#L<start>[-<end>]` fragment into 1-based lines.
    /// Lenient by design, so a reference ALWAYS opens the file (never fails
    /// over the fragment): a missing fragment or a non-numeric range yields
    /// nil lines ("open the file, skip the scroll"); a bare number without
    /// the `L` prefix is accepted as the line; and a range whose end is
    /// missing or backwards still opens at the start line.
    private static func lines(fromFragment fragment: String?) -> (start: Int?, end: Int?) {
        guard let fragment else { return (nil, nil) }
        var body = fragment
        if body.hasPrefix("L") || body.hasPrefix("l") {
            body.removeFirst()
        }
        guard !body.isEmpty else { return (nil, nil) }
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return (nil, nil) }
        if parts.count == 2, let end = Int(parts[1]), end >= start {
            return (start, end)
        }
        return (start, start)
    }
}

extension Notification.Name {
    /// Posted by the transcript when the user clicks an agent-emitted
    /// `pi-file://` reference link, so the session's file browser opens the
    /// referenced file. Payload keys (both required): `"cwd"` — the
    /// `URL` of the session folder the link names, so a tab only reacts to
    /// its own links — and `"link"`, the parsed `FileReferenceLink`.
    /// Posted on the main thread; the browser's owning `SessionTab` observes
    /// it (cwd-scoped, `queue: .main`).
    public static let openFileReference = Notification.Name("FileReference.open")
}
