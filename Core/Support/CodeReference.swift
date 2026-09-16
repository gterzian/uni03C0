import Foundation

/// A frozen code reference: an exact `path:line-line` anchor plus the snippet
/// of code that was visible when the reference was made. Produced by the
/// read-only code view (file browser content pane) when the user copies a
/// selection, carried on the pasteboard in two representations (§1.2), and
/// rendered into prompt text by whichever composer the paste lands in.
///
/// The path is ABSOLUTE, canonicalized once at copy time (reusing
/// `SandboxPolicy.canonicalize`, which has the same symlink-resolution need as
/// the seatbelt policy): nothing stops a reference tagged in one project's
/// browser from being pasted into a *different* project's chat tab, and
/// storing only a project-relative path would silently mean something else —
/// or nothing — across that boundary. Rendering is therefore a pure function
/// of the reference and the *target* composer's `cwd`.
public struct CodeReference: Hashable, Sendable, Codable {
    /// Resolved, absolute path of the referenced file.
    public let absolutePath: String
    /// 1-based, inclusive start line of the snippet.
    public let startLine: Int
    /// 1-based, inclusive end line of the snippet.
    public let endLine: Int
    /// The exact text that was selected, captured at copy time. Never re-read
    /// from disk afterwards — this is the point of "frozen": the reference
    /// always shows what the user actually looked at, and stays self-contained
    /// for a file that no longer exists (§2.6).
    public let snippet: String

    public init(absolutePath: String, startLine: Int, endLine: Int, snippet: String) {
        self.absolutePath = absolutePath
        self.startLine = startLine
        self.endLine = endLine
        self.snippet = snippet
    }

    /// Renders the reference to prompt text, relative to the composer's
    /// working directory:
    ///
    ///     [Ref: ../OtherProject/Core/Renderer.swift:118-126]   (cross-project)
    ///     [Ref: Core/Renderer.swift:118-126]                    (same project)
    ///     ```swift
    ///     …snippet…
    ///     ```
    ///
    /// The composer's `cwd` is canonicalized here (the reference's path was
    /// canonicalized at copy time) so a symlinked working folder still
    /// collapses to the same-project form instead of producing a bogus `..`.
    public func promptText(relativeTo cwd: URL) -> String {
        let canonicalBase = SandboxPolicy.canonicalize(cwd.path)
        let relative = RelativePath.compute(
            from: URL(fileURLWithPath: canonicalBase),
            to: URL(fileURLWithPath: absolutePath)
        )
        let anchor = endLine == startLine
            ? "\(relative):\(startLine)"
            : "\(relative):\(startLine)-\(endLine)"

        var text = "[Ref: \(anchor)]\n"
        if let language = Self.fenceLanguage(forPath: absolutePath) {
            text += "```\(language)\n"
        } else {
            text += "```\n"
        }
        text += snippet
        if !snippet.hasSuffix("\n") {
            text += "\n"
        }
        text += "```"
        return text
    }

    /// The fenced block's language tag for a path's extension. Same idea as
    /// the `toolName` → SF Symbol switch in `ToolCallCardView`, and reused by
    /// the content pane's syntax highlighter (the names are highlight.js
    /// language identifiers).
    public static func fenceLanguage(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return fenceLanguages[ext]
    }

    private static let fenceLanguages: [String: String] = [
        "swift": "swift",
        "c": "c",
        "h": "c",
        "m": "objectivec",
        "mm": "objectivec",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "py": "python",
        "rb": "ruby",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "js": "javascript",
        "mjs": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "json": "json",
        "md": "markdown",
        "markdown": "markdown",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "ini",
        "rs": "rust",
        "go": "go",
        "java": "java",
        "kt": "kotlin",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "sql": "sql",
        "xml": "xml",
        "plist": "xml",
        "cs": "csharp",
        "php": "php",
        "dockerfile": "dockerfile",
        "svelte": "xml",
        "vue": "xml",
    ]
}
